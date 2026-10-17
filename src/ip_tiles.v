`default_nettype none

module ip_tiles #(
    parameter MAX_TILES      = 2,
    parameter TILE_W         = 120,
    parameter TILE_H         = 80,
    parameter HIT_Y          = 400,
    parameter HIT_ZONE       = 60,
    parameter [3:0] LEVEL_UP_AT = 4'd15
) (
    input  wire       clk, rst_n, step,
    input  wire [3:0] btn,
    input  wire [9:0] x, y,
    input  wire       active,
    output reg  [5:0] rgb
);
    localparam IDX_W = $clog2(MAX_TILES);

    // ------------------------------------------------------------------
    // button edge detection
    // ------------------------------------------------------------------
    reg  [3:0] btn_prev;
    always @(posedge clk) btn_prev <= btn;
    wire [3:0] btn_pushed = btn & ~btn_prev;
    wire       any_pushed = |btn_pushed;

    wire [3:0] lane_active = btn;

    // ------------------------------------------------------------------
    // per-tile state
    // ------------------------------------------------------------------
    reg  [9:0]  tile_y     [0:MAX_TILES-1];
    reg  [1:0]  tile_lane  [0:MAX_TILES-1];
    reg  [10:0] tile_x     [0:MAX_TILES-1];
    reg         tile_alive [0:MAX_TILES-1];

    // game-state registers
    reg  [5:0] spawn_count;
    reg  [3:0] lfsr;
    reg  [3:0] level_progress;
    reg  [2:0] level;
    reg        ended;
    reg        is_win;              // ← NEW: distinguishes win from loss

    reg  [4:0] speed_cur;
    reg  [5:0] interval_cur;

    wire restart_clear = ended && any_pushed;

    always @(posedge clk) begin
        case (level)
            3'd2: begin speed_cur <= 5'd6;  interval_cur <= 6'd20; end
            3'd3: begin speed_cur <= 5'd8;  interval_cur <= 6'd15; end
            3'd4: begin speed_cur <= 5'd10; interval_cur <= 6'd14; end
            3'd5: begin speed_cur <= 5'd12; interval_cur <= 6'd12; end
            default: begin speed_cur <= 5'd4; interval_cur <= 6'd30; end
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

    wire progress_up   =  any_hit && !any_wrong_press;
    wire progress_down = !any_hit &&  any_wrong_press;

    // ------------------------------------------------------------------
    // spawn slot finder
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

    wire [1:0]  next_lane    = lfsr[1:0];
    wire [10:0] next_lane_x  = 11'd20
                             + {2'd0, next_lane, 7'd0}
                             + {4'd0, next_lane, 5'd0};

    wire spawn_due   = step && !ended
                       && (spawn_count >= interval_cur - 6'd1);
    wire spawn_pulse = spawn_due && spawn_slot_free;

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
                    tile_x[g]     <= 11'd20;
                end else if (spawn_pulse && (spawn_idx == G_IDX)) begin
                    tile_alive[g] <= 1'b1;
                    tile_y[g]     <= 10'd0;
                    tile_lane[g]  <= next_lane;
                    tile_x[g]     <= next_lane_x;
                end else if (hittable[g] || miss_vec[g]) begin
                    tile_alive[g] <= 1'b0;
                end else if (step && !ended && tile_alive[g]) begin
                    tile_y[g] <= tile_y[g] + speed_cur;
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // game state machine — demote on miss, die at level 1
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n || restart_clear) begin
            spawn_count    <= 6'd0;
            level_progress <= 4'd0;
            level          <= 3'd1;
            ended          <= 1'b0;
            is_win         <= 1'b0;         // ← reset win flag
            if (!rst_n) lfsr <= 4'hA;
        end else if (!ended) begin
            if (spawn_due) begin
                spawn_count <= 6'd0;
                if (spawn_pulse)
                    lfsr <= {lfsr[2:0], lfsr[3]^lfsr[0]};
            end else if (step) begin
                spawn_count <= spawn_count + 6'd1;
            end

            if (progress_up) begin
                if (level_progress == LEVEL_UP_AT) begin
                    level_progress <= 4'd0;
                    if (level < 3'd5)
                        level <= level + 3'd1;
                    else begin
                        ended  <= 1'b1;
                        is_win <= 1'b1;     // ← win: completed level 5
                    end
                end else begin
                    level_progress <= level_progress + 4'd1;
                end
            end else if (progress_down && level_progress > 4'd0) begin
                level_progress <= level_progress - 4'd1;
            end

            if (any_miss) begin
                if (level == 3'd1) begin
                    ended  <= 1'b1;
                    is_win <= 1'b0;         // ← loss: missed at level 1
                end else begin
                    level          <= level - 3'd1;
                    level_progress <= 4'd0;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // tile rendering (cached tile_x)
    // ------------------------------------------------------------------
    wire [MAX_TILES-1:0] tile_pixel;
    generate
        for (g = 0; g < MAX_TILES; g = g + 1) begin : tile_render
            wire [10:0] x11   = {1'b0, x};
            wire [10:0] y11   = {1'b0, y};
            wire [10:0] tx_lo = tile_x[g];
            wire [10:0] tx_hi = tile_x[g] + TILE_W;
            wire [10:0] ty_lo = {1'b0, tile_y[g]};
            wire [10:0] ty_hi = ty_lo + TILE_H;
            assign tile_pixel[g] = tile_alive[g]
                                   && (x11 >= tx_lo) && (x11 < tx_hi)
                                   && (y11 >= ty_lo) && (y11 < ty_hi);
        end
    endgenerate
    wire any_tile_pixel = |tile_pixel;

    // ------------------------------------------------------------------
    // 5-segment progress bar (one segment per level, single colour)
    // ------------------------------------------------------------------
    wire [9:0] bar_right = ({7'd0, level}              << 7)
                         + ({5'd0, level_progress}     << 3)
                         - 10'd120;
    wire bar_pixel = (y < 10'd8) && (x < bar_right);

    // ------------------------------------------------------------------
    // hit line + press highlight
    // ------------------------------------------------------------------
    wire [10:0] y11_hud = {1'b0, y};
    wire on_hit_line = (y11_hud >= HIT_Y) && (y11_hud < HIT_Y + 11'd2);

    wire [1:0] x_lane = (x < 10'd160) ? 2'd0 :
                        (x < 10'd320) ? 2'd1 :
                        (x < 10'd480) ? 2'd2 : 2'd3;
    wire hit_line_pressed = on_hit_line && lane_active[x_lane];

    // ------------------------------------------------------------------
    // lane dividers
    // ------------------------------------------------------------------
    wire lane_div = (x == 10'd160) || (x == 10'd320) || (x == 10'd480);

    // ------------------------------------------------------------------
    // colour priority — GREEN win, RED loss
    // ------------------------------------------------------------------
    always @(*) begin
        if (!active)                rgb = 6'b00_00_00;
        else if (ended && is_win)   rgb = 6'b00_11_00;   // ← green victory
        else if (ended)             rgb = 6'b11_00_00;   // red defeat
        else if (any_tile_pixel)    rgb = 6'b11_11_11;   // white tile
        else if (bar_pixel)         rgb = 6'b00_11_00;   // green progress bar
        else if (hit_line_pressed)  rgb = 6'b11_11_00;   // yellow pressed lane
        else if (on_hit_line)       rgb = 6'b00_11_11;   // cyan default
        else if (lane_div)          rgb = 6'b01_01_01;   // grey dividers
        else                        rgb = 6'b00_00_01;   // dark blue background
    end
endmodule
