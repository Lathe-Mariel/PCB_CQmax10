`default_nettype none

module hid_keyboard_ascii (
    input  wire logic       clk,
    input  wire logic       rst_n,
    input  wire logic [1:0] typ,
    input  wire logic       report,
    input  wire logic [7:0] key_modifiers,
    input  wire logic [7:0] key1,
    input  wire logic [7:0] key2,
    input  wire logic [7:0] key3,
    input  wire logic [7:0] key4,
    output logic [7:0] ascii,
    output logic       ascii_valid
);

    localparam logic [1:0] TYPE_KEYBOARD = 2'd1;
    localparam logic [7:0] HID_CAPS_LOCK = 8'h39;

    logic [7:0] prev_key1;
    logic [7:0] prev_key2;
    logic [7:0] prev_key3;
    logic [7:0] prev_key4;
    logic       caps_lock;

    logic       shift_active;
    logic [7:0] new_key;
    logic [7:0] mapped_ascii;

    assign shift_active = key_modifiers[1] | key_modifiers[5];

    function automatic logic key_is_pressed(
        input logic [7:0] key,
        input logic [7:0] a,
        input logic [7:0] b,
        input logic [7:0] c,
        input logic [7:0] d
    );
        key_is_pressed = (key != 8'h00) && ((key == a) || (key == b) || (key == c) || (key == d));
    endfunction

    function automatic logic key_can_emit(input logic [7:0] key);
        key_can_emit = (key >= 8'h04);
    endfunction

    function automatic logic [7:0] first_new_key(
        input logic [7:0] k1,
        input logic [7:0] k2,
        input logic [7:0] k3,
        input logic [7:0] k4,
        input logic [7:0] p1,
        input logic [7:0] p2,
        input logic [7:0] p3,
        input logic [7:0] p4
    );
        begin
            first_new_key = 8'h00;
            if (key_can_emit(k1) && !key_is_pressed(k1, p1, p2, p3, p4)) begin
                first_new_key = k1;
            end else if (key_can_emit(k2) && !key_is_pressed(k2, p1, p2, p3, p4)) begin
                first_new_key = k2;
            end else if (key_can_emit(k3) && !key_is_pressed(k3, p1, p2, p3, p4)) begin
                first_new_key = k3;
            end else if (key_can_emit(k4) && !key_is_pressed(k4, p1, p2, p3, p4)) begin
                first_new_key = k4;
            end
        end
    endfunction

    function automatic logic [7:0] hid_to_ascii(
        input logic [7:0] key,
        input logic       shift,
        input logic       caps
    );
        logic upper;
        begin
            hid_to_ascii = 8'h00;
            upper = shift ^ caps;

            if ((key >= 8'h04) && (key <= 8'h1d)) begin
                hid_to_ascii = 8'h61 + (key - 8'h04);
                if (upper) begin
                    hid_to_ascii = hid_to_ascii - 8'h20;
                end
            end else begin
                unique case (key)
                    8'h1e: hid_to_ascii = shift ? 8'h21 : 8'h31;
                    8'h1f: hid_to_ascii = shift ? 8'h40 : 8'h32;
                    8'h20: hid_to_ascii = shift ? 8'h23 : 8'h33;
                    8'h21: hid_to_ascii = shift ? 8'h24 : 8'h34;
                    8'h22: hid_to_ascii = shift ? 8'h25 : 8'h35;
                    8'h23: hid_to_ascii = shift ? 8'h5e : 8'h36;
                    8'h24: hid_to_ascii = shift ? 8'h26 : 8'h37;
                    8'h25: hid_to_ascii = shift ? 8'h2a : 8'h38;
                    8'h26: hid_to_ascii = shift ? 8'h28 : 8'h39;
                    8'h27: hid_to_ascii = shift ? 8'h29 : 8'h30;
                    8'h28: hid_to_ascii = 8'h0a;
                    8'h29: hid_to_ascii = 8'h1b;
                    8'h2a: hid_to_ascii = 8'h08;
                    8'h2b: hid_to_ascii = 8'h09;
                    8'h2c: hid_to_ascii = 8'h20;
                    8'h2d: hid_to_ascii = shift ? 8'h5f : 8'h2d;
                    8'h2e: hid_to_ascii = shift ? 8'h2b : 8'h3d;
                    8'h2f: hid_to_ascii = shift ? 8'h7b : 8'h5b;
                    8'h30: hid_to_ascii = shift ? 8'h7d : 8'h5d;
                    8'h31: hid_to_ascii = shift ? 8'h7c : 8'h5c;
                    8'h33: hid_to_ascii = shift ? 8'h3a : 8'h3b;
                    8'h34: hid_to_ascii = shift ? 8'h22 : 8'h27;
                    8'h35: hid_to_ascii = shift ? 8'h7e : 8'h60;
                    8'h36: hid_to_ascii = shift ? 8'h3c : 8'h2c;
                    8'h37: hid_to_ascii = shift ? 8'h3e : 8'h2e;
                    8'h38: hid_to_ascii = shift ? 8'h3f : 8'h2f;
                    default: hid_to_ascii = 8'h00;
                endcase
            end
        end
    endfunction

    always_comb begin
        new_key      = first_new_key(key1, key2, key3, key4, prev_key1, prev_key2, prev_key3, prev_key4);
        mapped_ascii = hid_to_ascii(new_key, shift_active, caps_lock);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_key1    <= 8'h00;
            prev_key2    <= 8'h00;
            prev_key3    <= 8'h00;
            prev_key4    <= 8'h00;
            caps_lock    <= 1'b0;
            ascii        <= 8'h00;
            ascii_valid  <= 1'b0;
        end else begin
            ascii_valid <= 1'b0;

            if (report) begin
                if (typ == TYPE_KEYBOARD) begin
                    prev_key1 <= key1;
                    prev_key2 <= key2;
                    prev_key3 <= key3;
                    prev_key4 <= key4;

                    if (new_key == HID_CAPS_LOCK) begin
                        caps_lock <= ~caps_lock;
                    end else if (mapped_ascii != 8'h00) begin
                        ascii       <= mapped_ascii;
                        ascii_valid <= 1'b1;
                    end
                end else begin
                    prev_key1 <= 8'h00;
                    prev_key2 <= 8'h00;
                    prev_key3 <= 8'h00;
                    prev_key4 <= 8'h00;
                end
            end
        end
    end

endmodule

`default_nettype wire
