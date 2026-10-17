`default_nettype none

module ip_tiles #(
    parameter MAX_TILES      = 5,
    parameter TILE_W         = 120,
    parameter TILE_H         = 80,
    parameter HIT_Y          = 400,
    parameter HIT_ZONE       = 60,
    parameter [7:0] SCORE_WIN     = 8'd128,
    parameter [4:0] FLASH_FRAMES  = 5'd12,
    parameter [4:0] LEVEL_UP_AT   = 5'd15
) (
    input  wire       clk, rst_n, step,
    input  wire [3:0] btn,
    input  wire [9:0] x, y,
    input  wire       active,
    output reg  [5:0] rgb
);
    localparam IDX_W = $clog2(MAX_TILES);

    // score digit layout (centred)
    localparam [9:0] DIG_X0    = 10'd292;
    localparam [9:0] DIG_Y0    = 10'd4;
    localparam [9:0] DIG_PITCH = 10'd20;
    localparam [9:0] DIG_W     = 10'd16;
    localparam [9:0] DIG_H     = 10'd24;

    function [9:0] lane_offset;
        input [1:0] lane;
        begin
            case (lane)
                2'd0: lane_offset = 10'd20;
                2'd1: lane_offset = 10'd180;
                2'd2: lane_offset = 10'd340;
                2'd3: lane_offset = 10'd500;
            endcase
        end
    endfunction

    // 7-seg pattern decoder: {A,B,C,D,E,F,G}
    function [6:0] seg_pattern;
        input [3:0] d;
        begin
            case (d)
                4'd0: seg_pattern = 7'b1111110;
                4'd1: seg_pattern = 7'b0110000;
                4'd2: seg_pattern = 7'b1101101;
                4'd3: seg_pattern = 7'b1111001;
                4'd4: seg_pattern = 7'b0110011;
                4'd5: seg_pattern = 7'b1011011;
                4'd6: seg_pattern = 7'b1011111;
                4'd7: seg_pattern = 7'b1110000;
                4'd8: seg_pattern = 7'b1111111;
                default: seg_pattern = 7'b1111011;   // 9
            endcase
        end
    endfunction

    // 7-seg pixel test inside a single digit cell
    function seg_pixel;
        input [6:0] segs;
        input [5:0] xl, yl;
        begin
            seg_pixel =
                ( (xl >= 6'd2)  && (xl < 6'd14) && (yl < 6'd2)                    && segs[6] ) ||
                ( (xl >= 6'd14) && (xl < 6'd16) && (yl >= 6'd2)  && (yl < 6'd11)  && segs[5] ) ||
                ( (xl >= 6'd14) && (xl < 6'd16) && (yl >= 6'd13) && (yl < 6'd22)  && segs[4] ) ||
                ( (xl >= 6'd2)  && (xl < 6'd14) && (yl >= 6'd22) && (yl < 6'd24)  && segs[3] ) ||
                ( (xl < 6'd2)                   && (yl >= 6'd13) && (yl < 6'd22)  && segs[2] ) ||
                ( (xl < 6'd2)                   && (yl >= 6'd2)  && (yl < 6'd11)  && segs[1] ) ||
                ( (xl >= 6'd2)  && (xl < 6'd14) && (yl >= 6'd11) && (yl < 6'd13)  && segs[0] );
        end
    endfunction

    // ------------------------------------------------------------------
    // button edge detection
    // ------------------------------------------------------------------
    reg  [3:0] btn_prev;
    always @(posedge clk) btn_prev <= btn;
    wire [3:0] btn_pushed = btn & ~btn_prev;
    wire       any_pushed = |btn_pushed;

    // per-lane hit-line flash
    reg  [4:0] flash_cnt [0:3];
    wire [3:0] lane_active;
    genvar fb;
    generate
        for (fb = 0; fb < 4; fb = fb + 1) begin : flash_gen
            always @(posedge clk) begin
                if (!rst_n)                  flash_cnt[fb] <= 5'd0;
                else if (btn_pushed[fb])     flash_cnt[fb] <= FLASH_FRAMES;
                else if (flash_cnt[fb] != 0) flash_cnt[fb] <= flash_cnt[fb] - 5'd1;
            end
            assign lane_active[fb] = btn[fb] | (flash_cnt[fb] != 5'd0);
        end
    endgenerate

    // ------------------------------------------------------------------
    // per-tile state
    // ------------------------------------------------------------------
    reg  [9:0] tile_y     [0:MAX_TILES-1];
    reg  [1:0] tile_lane  [0:MAX_TILES-1];
    reg        tile_alive [0:MAX_TILES-1];

    // game state
    reg  [7:0] spawn_count;
    reg  [7:0] lfsr;
    reg  [1:0] prev_lane;
    reg  [7:0] score;
    reg  [1:0] lives;
    reg  [2:0] level;
    reg  [4:0] level_progress;
    reg        game_over;
    reg        won;

    wire restart_clear = (game_over || won) && any_pushed;

    // difficulty table
    reg [9:0] speed_cur;
    reg [7:0] interval_cur;
    always @(posedge clk) begin
        case (level)
            3'd2: begin speed_cur <= 10'd6;  interval_cur <= 8'd20; end
            3'd3: begin speed_cur <= 10'd8;  interval_cur <= 8'd15; end
            3'd4: begin speed_cur <= 10'd10; interval_cur <= 8'd12; end
            3'd5: begin speed_cur <= 10'd12; interval_cur <= 8'd10; end
            default: begin speed_cur <= 10'd4; interval_cur <= 8'd30; end
        endcase
    end

    // ------------------------------------------------------------------
    // tile geometry + zone checks
    // ------------------------------------------------------------------
    wire [10:0] tile_bottom [0:MAX_TILES-1];
    wire [MAX_TILES-1:0] in_zone, miss_vec, hittable;
    genvar g;
    generate
        for (g = 0; g < MAX_TILES; g = g + 1) begin : tile_eval
            assign tile_bottom[g] = {1'b0, tile_y[g]} + TILE_H;
            assign miss_vec[g]    = tile_alive[g]
                                    && (tile_bottom[g] > HIT_Y + HIT_ZONE);
            assign in_zone[g]     = tile_alive[g]
                                    && (tile_bottom[g] >= HIT_Y)
                                    && (tile_bottom[g] <= HIT_Y + HIT_ZONE);
            assign hittable[g]    = in_zone[g] && btn_pushed[tile_lane[g]];
        end
    endgenerate

    wire any_hit  = |hittable;
    wire any_miss = |miss_vec;

    // per-lane presence
    wire [3:0] lane_has_tile;
    generate
        for (g = 0; g < 4; g = g + 1) begin : lane_pres
            wire [MAX_TILES-1:0] hits_lane;
            for (genvar t = 0; t < MAX_TILES; t = t + 1) begin : per_tile
                assign hits_lane[t] = in_zone[t] && (tile_lane[t] == g[1:0]);
            end
            assign lane_has_tile[g] = |hits_lane;
        end
    endgenerate

    wire [3:0] wrong_press     = btn_pushed & ~lane_has_tile;
    wire       any_wrong_press = |wrong_press;

    wire score_up   =  any_hit && !any_wrong_press;
    wire score_down = !any_hit &&  any_wrong_press;

    // ------------------------------------------------------------------
    // spawn slot finder + lane picker
    // ------------------------------------------------------------------
    reg [IDX_W-1:0] spawn_idx;
    reg             spawn_slot_free;
    always @(*) begin
        integer kk;
        spawn_idx       = {IDX_W{1'b0}};
        spawn_slot_free = 1'b0;
        for (kk = MAX_TILES-1; kk >= 0; kk = kk - 1)
            if (!tile_alive[kk]) begin
                spawn_idx       = kk[IDX_W-1:0];
                spawn_slot_free = 1'b1;
            end
    end

    wire [1:0] next_lane  = (lfsr[1:0] == prev_lane) ? (prev_lane + 2'd1) : lfsr[1:0];
    wire spawn_due        = step && !game_over && !won
                            && (spawn_count >= interval_cur - 8'd1);
    wire spawn_pulse      = spawn_due && spawn_slot_free;

    // ------------------------------------------------------------------
    // per-tile always blocks
    // ------------------------------------------------------------------
    generate
        for (g = 0; g < MAX_TILES; g = g + 1) begin : tile_state
            localparam [IDX_W-1:0] G_IDX = g;
            always @(posedge clk) begin
                if (!rst_n || restart_clear) begin
                    tile_alive[g] <= 1'b0;
                    tile_y[g]     <= 10'd0;
                    tile_lane[g]  <= 2'd0;
                end else if (spawn_pulse && (spawn_idx == G_IDX)) begin
                    tile_alive[g] <= 1'b1;
                    tile_y[g]     <= 10'd0;
                    tile_lane[g]  <= next_lane;
                end else if (hittable[g]) begin
                    tile_alive[g] <= 1'b0;
                end else if (miss_vec[g]) begin
                    tile_alive[g] <= 1'b0;               // deactivate on miss
                end else if (step && !game_over && !won
                             && tile_alive[g] && !miss_vec[g]) begin
                    tile_y[g] <= tile_y[g] + speed_cur;
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // game state machine
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            spawn_count <= 8'd0; score <= 8'd0;
            lives <= 2'd3; level <= 3'd1; level_progress <= 5'd0;
            game_over <= 1'b0; won <= 1'b0; lfsr <= 8'hA5; prev_lane <= 2'd0;
        end else if (restart_clear) begin
            spawn_count <= 8'd0; score <= 8'd0;
            lives <= 2'd3; level <= 3'd1; level_progress <= 5'd0;
            game_over <= 1'b0; won <= 1'b0; prev_lane <= 2'd0;
        end else if (!game_over && !won) begin
            if (spawn_due) begin
                spawn_count <= 8'd0;
                if (spawn_pulse) begin
                    prev_lane <= next_lane;
                    lfsr      <= {lfsr[6:0], lfsr[7]^lfsr[5]^lfsr[4]^lfsr[3]};
                end
            end else if (step) begin
                spawn_count <= spawn_count + 8'd1;
            end

            if (score_up) begin
                if (score >= SCORE_WIN - 8'd1) begin
                    score <= SCORE_WIN;
                    won   <= 1'b1;
                end else begin
                    score <= score + 8'd1;
                end
            end else if (score_down && score > 8'd0) begin
                score <= score - 8'd1;
            end

            if (any_miss) begin
                if (lives == 2'd1) game_over <= 1'b1;
                if (lives != 2'd0) lives     <= lives - 2'd1;
            end

            if (any_hit) begin
                if (level_progress == LEVEL_UP_AT) begin
                    level_progress <= 5'd0;
                    if (level < 3'd5) level <= level + 3'd1;
                end else begin
                    level_progress <= level_progress + 5'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // tile rendering
    // ------------------------------------------------------------------
    wire [MAX_TILES-1:0] tile_pixel;
    generate
        for (g = 0; g < MAX_TILES; g = g + 1) begin : tile_render
            wire [10:0] x11   = {1'b0, x};
            wire [10:0] y11   = {1'b0, y};
            wire [10:0] tx_lo = {1'b0, lane_offset(tile_lane[g])};
            wire [10:0] tx_hi = tx_lo + TILE_W;
            wire [10:0] ty_lo = {1'b0, tile_y[g]};
            wire [10:0] ty_hi = ty_lo + TILE_H;
            assign tile_pixel[g] = tile_alive[g]
                                   && (x11 >= tx_lo) && (x11 < tx_hi)
                                   && (y11 >= ty_lo) && (y11 < ty_hi);
        end
    endgenerate
    wire any_tile_pixel = |tile_pixel;

    // ------------------------------------------------------------------
    // HUD: SCORE DIGITS (comparator-chain BCD, no multiplier)
    // ------------------------------------------------------------------
    wire [7:0] s_val      = score;
    wire [3:0] h_dig      = (s_val >= 8'd100) ? 4'd1 : 4'd0;
    wire [7:0] s_after_h  = s_val - (h_dig == 4'd1 ? 8'd100 : 8'd0);

    wire [3:0] t_dig      = (s_after_h >= 8'd90) ? 4'd9 :
                            (s_after_h >= 8'd80) ? 4'd8 :
                            (s_after_h >= 8'd70) ? 4'd7 :
                            (s_after_h >= 8'd60) ? 4'd6 :
                            (s_after_h >= 8'd50) ? 4'd5 :
                            (s_after_h >= 8'd40) ? 4'd4 :
                            (s_after_h >= 8'd30) ? 4'd3 :
                            (s_after_h >= 8'd20) ? 4'd2 :
                            (s_after_h >= 8'd10) ? 4'd1 : 4'd0;

    wire [7:0] tens_x10   = ({4'b0, t_dig} << 3) + ({4'b0, t_dig} << 1);
    wire [7:0] ones_full  = s_after_h - tens_x10;
    wire [3:0] o_dig      = ones_full[3:0];

    wire [6:0] segs_h = seg_pattern(h_dig);
    wire [6:0] segs_t = seg_pattern(t_dig);
    wire [6:0] segs_o = seg_pattern(o_dig);

    wire [9:0] rx_h = x - DIG_X0;
    wire [9:0] rx_t = x - DIG_X0 - DIG_PITCH;
    wire [9:0] rx_o = x - DIG_X0 - 2*DIG_PITCH;
    wire [9:0] ry_d = y - DIG_Y0;

    wire h_lit = (rx_h < DIG_W) && (ry_d < DIG_H) && seg_pixel(segs_h, rx_h[5:0], ry_d[5:0]);
    wire t_lit = (rx_t < DIG_W) && (ry_d < DIG_H) && seg_pixel(segs_t, rx_t[5:0], ry_d[5:0]);
    wire o_lit = (rx_o < DIG_W) && (ry_d < DIG_H) && seg_pixel(segs_o, rx_o[5:0], ry_d[5:0]);
    wire score_digit_pixel = h_lit || t_lit || o_lit;

    // hearts (lives), top-right
    wire in_h0 = (x >= 10'd570) && (x < 10'd586) && (y >= 10'd4) && (y < 10'd20);
    wire in_h1 = (x >= 10'd592) && (x < 10'd608) && (y >= 10'd4) && (y < 10'd20);
    wire in_h2 = (x >= 10'd614) && (x < 10'd630) && (y >= 10'd4) && (y < 10'd20);
    wire heart_pixel = (in_h0 && lives >= 2'd1) ||
                       (in_h1 && lives >= 2'd2) ||
                       (in_h2 && lives >= 2'd3);

    // hit line
    wire [10:0] y11_hud = {1'b0, y};
    wire on_hit_line = (y11_hud >= HIT_Y) && (y11_hud < HIT_Y + 11'd2);

    wire [1:0] x_lane  = (x < 10'd160) ? 2'd0 :
                         (x < 10'd320) ? 2'd1 :
                         (x < 10'd480) ? 2'd2 : 2'd3;
    wire hit_line_pressed = on_hit_line && lane_active[x_lane];

    wire lane_div = (x == 10'd0) || (x == 10'd160) || (x == 10'd320)
                    || (x == 10'd480) || (x == 10'd639);

    // ------------------------------------------------------------------
    // colour priority
    // ------------------------------------------------------------------
    always @(*) begin
        if (!active)                  rgb = 6'b00_00_00;
        else if (won)                 rgb = 6'b00_11_00;
        else if (game_over)           rgb = 6'b11_00_00;
        else if (any_tile_pixel)      rgb = 6'b11_11_11;
        else if (score_digit_pixel)   rgb = 6'b11_11_00;
        else if (hit_line_pressed)    rgb = 6'b11_11_00;
        else if (on_hit_line)         rgb = 6'b00_11_11;
        else if (heart_pixel)         rgb = 6'b11_00_00;
        else if (lane_div)            rgb = 6'b01_01_01;
        else                          rgb = 6'b00_00_01;
    end
endmodule
