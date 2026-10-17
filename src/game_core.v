`default_nettype none
module game_core #(
    parameter DB = 250000    // 10 ms at 25 MHz (snappier than 20 ms for rhythm play)
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [3:0] btn,       // raw buttons
    input  wire [9:0] x, y,
    input  wire       active,
    input  wire       frame,
    output wire [5:0] rgb
);
    wire [3:0] btn_clean;
    generate
        for (genvar b = 0; b < 4; b = b + 1) begin : db
            ip_debounce #(.N(DB)) u_db (
                .clk(clk), .rst_n(rst_n),
                .noisy(btn[b]), .clean(btn_clean[b])
            );
        end
    endgenerate

    ip_tiles tiles (
        .clk(clk), .rst_n(rst_n),
        .step(frame),
        .btn(btn_clean),
        .x(x), .y(y), .active(active),
        .rgb(rgb)
    );
endmodule
