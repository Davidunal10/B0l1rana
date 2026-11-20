
// 1. MÓDULO TOP-LEVEL
module proyecto_final_uno (
    input  wire       clk_50mhz,   // Reloj principal (Pin 23)
    input  wire       rst_n,       // Reset maestro activo en bajo
    input  wire [2:0] sw_limit,    // DIP switches para meta de puntaje
    input  wire [3:0] ir_sensors,  // Entradas sensores IR (Agujeros 1 al 4)
    input  wire       btn_change,  // Botón 1: Cambiar letra / Incrementar jugadores
    input  wire       btn_next,    // Botón 2: Confirmar / Siguiente / Cambio de turno
    inout  wire       i2c_sda,     // Línea de Datos I2C (SDA)
    output wire       i2c_scl,     // Línea de Reloj I2C (SCL)
    output wire       buzzer        // Buzzer integrado, PIN_141, activo en bajo
);

    wire [3:0]   clean_ir_pulses;
    wire         clean_btn_change;
    wire         clean_btn_next;
    wire [15:0]  target_score;
    wire [31:0]  target_ascii;
    wire [2:0]   game_state;
    wire [1:0]   total_players;
    wire [1:0]   current_player;
    wire [23:0]  active_name;
    wire [15:0]  active_score;
    wire [127:0] line1_text;
    wire [127:0] line2_text;
    wire [1:0]   score_sfx;       
    wire         win_sfx;         

    limit_selector limit_inst (
        .sw_limit(sw_limit),
        .target_score(target_score),
        .target_ascii(target_ascii)
    );
// Filtros de sensores
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : ir_sensor_filter
            ir_sensor_lockout #(
                .LOCKOUT_CYCLES(32'd25_000_000) 
            ) ir_filt (
                .clk(clk_50mhz),
                .reset_n(rst_n),
					 .signal_in(ir_sensors[i]),
                .pulse_out(clean_ir_pulses[i])
            );
        end
    endgenerate

    // 3. Filtros antirrebote para botones de control (20 ms)
    button_debouncer #(
        .STABLE_CYCLES(20'd1000000) 
    ) btn_chg_filt (
        .clk(clk_50mhz),
        .reset_n(rst_n),
        .signal_in(btn_change),
        .pulse_out(clean_btn_change)
    );

    button_debouncer #(
        .STABLE_CYCLES(20'd1000000) 
    ) btn_nxt_filt (
        .clk(clk_50mhz),
        .reset_n(rst_n),
        .signal_in(btn_next),
        .pulse_out(clean_btn_next)
    );

    // 4. Máquina de Estados Finitos (FSM) Principal del Juego
    multi_player_game_fsm game_core (
        .clk(clk_50mhz),
        .reset_n(rst_n),
        .btn_change_pulse(clean_btn_change),
        .btn_next_pulse(clean_btn_next),
        .ir_pulses(clean_ir_pulses),
        .target_score(target_score),
        .active_name(active_name),
        .active_score(active_score),
        .game_state(game_state),
        .current_player(current_player),
        .total_players(total_players),
        .score_sfx(score_sfx),
        .win_sfx(win_sfx)
    );

    // 5. Formateador de texto ASCII para la pantalla LCD
    lcd_formatter lcd_fmt_inst (
        .game_state(game_state),
        .total_players(total_players),
        .current_player(current_player),
        .active_name(active_name),
        .active_score(active_score),
        .target_ascii(target_ascii),
        .line1_text(line1_text),
        .line2_text(line2_text)
    );

    // 6. Controlador Maestro I2C para LCD 16x2
    i2c_lcd_16x2_controller i2c_ctrl_inst (
        .clk(clk_50mhz),
        .reset_n(rst_n),
        .line1_text(line1_text),
        .line2_text(line2_text),
        .scl(i2c_scl),
        .sda(i2c_sda)
    );

    // 7. Sonidos de botones, puntos y victoria con el buzzer de la placa
    bolirana_buzzer buzzer_inst (
        .clk(clk_50mhz),
        .reset_n(rst_n),
        .btn_change_pulse(clean_btn_change),
        .btn_next_pulse(clean_btn_next),
        .score_sfx(score_sfx),
        .win_sfx(win_sfx),
        .buzzer(buzzer)
    );

endmodule

// 2. FILTRO SENSOR IR CON LOCKOUT DE 500 ms
module ir_sensor_lockout #(
    parameter [31:0] LOCKOUT_CYCLES = 32'd25_000_000 
)(
    input  wire clk,
    input  wire reset_n,
    input  wire signal_in,
    output reg  pulse_out
);

    reg sync_0, sync_1;
    reg state_prev;
    reg [31:0] lockout_cnt;
    reg in_lockout;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sync_0 <= 1'b1;
            sync_1 <= 1'b1;
        end else begin
            sync_0 <= signal_in;
            sync_1 <= sync_0;
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state_prev  <= 1'b1;
            pulse_out   <= 1'b0;
            lockout_cnt <= 32'd0;
            in_lockout  <= 1'b0;
        end else begin
            state_prev <= sync_1;

            if (in_lockout) begin
                pulse_out <= 1'b0;
                if (lockout_cnt >= LOCKOUT_CYCLES) begin
                    in_lockout  <= 1'b0;
                    lockout_cnt <= 32'd0;
                end else begin
                    lockout_cnt <= lockout_cnt + 1'b1;
                end
            end else begin
                if (state_prev == 1'b1 && sync_1 == 1'b0) begin
                    pulse_out   <= 1'b1;
                    in_lockout  <= 1'b1;
                    lockout_cnt <= 32'd0;
                end else begin
                    pulse_out   <= 1'b0;
                end
            end
        end
    end

endmodule

// 3. FILTRO ANTI-REBOTE PARA BOTONES MANUALES
module button_debouncer #(
    parameter [19:0] STABLE_CYCLES = 20'd1000000 
)(
    input  wire clk,
    input  wire reset_n,
    input  wire signal_in,
    output reg  pulse_out
);

    reg sync_0, sync_1;
    reg state;
    reg state_prev;
    reg [19:0] counter;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sync_0 <= 1'b1;
            sync_1 <= 1'b1;
        end else begin
            sync_0 <= signal_in;
            sync_1 <= sync_0;
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            counter <= 20'd0;
            state   <= 1'b1;
        end else begin
            if (sync_1 != state) begin
                counter <= counter + 1'b1;
                if (counter == STABLE_CYCLES) begin
                    state   <= sync_1;
                    counter <= 20'd0;
                end
            end else begin
                counter <= 20'd0;
            end
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state_prev <= 1'b1;
            pulse_out  <= 1'b0;
        end else begin
            state_prev <= state;
            pulse_out  <= (state_prev == 1'b1 && state == 1'b0);
        end
    end

endmodule

// 4. MÁQUINA DE ESTADOS Y LÓGICA DEL JUEGO

module multi_player_game_fsm (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        btn_change_pulse,
    input  wire        btn_next_pulse,
    input  wire [3:0]  ir_pulses,
    input  wire [15:0] target_score,
    output reg  [2:0]  game_state,       
    output reg  [1:0]  total_players,
    output reg  [1:0]  current_player,
    output reg  [23:0] active_name,
    output reg  [15:0] active_score,
    output reg  [1:0]  score_sfx,      
    output reg         win_sfx         
);

    localparam STATE_SETUP_PLAYERS = 3'd0;
    localparam STATE_SETUP_LIMIT   = 3'd1;
    localparam STATE_SETUP_NAME    = 3'd2;
    localparam STATE_GAME_PLAY     = 3'd3;
    localparam STATE_GAME_WIN      = 3'd4;

    reg [15:0] scores [0:3];
    reg [7:0]  name_l0 [0:3];
    reg [7:0]  name_l1 [0:3];
    reg [7:0]  name_l2 [0:3];

    reg [1:0]  char_idx;
    reg [7:0]  curr_edit_char;
    reg [31:0] global_cooldown;

    integer k;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            game_state      <= STATE_SETUP_PLAYERS;
            total_players   <= 2'd0;
            current_player  <= 2'd0;
            char_idx        <= 2'd0;
            curr_edit_char  <= 8'h41;      
            active_name     <= 24'h414141; 
            active_score    <= 16'd0;
            score_sfx       <= 2'd0;
            win_sfx         <= 1'b0;
            global_cooldown <= 32'd0;
            for (k = 0; k < 4; k = k + 1) begin
                scores[k]  <= 16'd0;
                name_l0[k] <= 8'h41;
                name_l1[k] <= 8'h41;
                name_l2[k] <= 8'h41;
            end
        end else begin

            score_sfx <= 2'd0;
            win_sfx   <= 1'b0;

            if (global_cooldown > 32'd0) begin
                global_cooldown <= global_cooldown - 1'b1;
            end

            case (game_state)
                // 0: SELECCIÓN DE CANTIDAD DE JUGADORES
                STATE_SETUP_PLAYERS: begin
                    active_score   <= 16'd0;
                    current_player <= 2'd0;

                    if (btn_change_pulse) begin
                        total_players <= (total_players == 2'd3) ? 2'd0 : total_players + 1'b1;
                    end

                    if (btn_next_pulse) begin
                        game_state <= STATE_SETUP_LIMIT;
                    end
                end

                // 1: PANTALLA DE CONFIRMACIÓN DE META DE PUNTAJE
                STATE_SETUP_LIMIT: begin
                    if (btn_next_pulse || btn_change_pulse) begin
                        char_idx       <= 2'd0;
                        curr_edit_char <= 8'h41;
                        active_name    <= 24'h414141;
                        game_state     <= STATE_SETUP_NAME;
                    end
                end

                // 2: SELECCIÓN DE INICIALES POR JUGADOR
                STATE_SETUP_NAME: begin
                    if (char_idx == 2'd0)
                        active_name <= {curr_edit_char, 8'h5F, 8'h5F};
                    else if (char_idx == 2'd1)
                        active_name <= {name_l0[current_player], curr_edit_char, 8'h5F};
                    else
                        active_name <= {name_l0[current_player], name_l1[current_player], curr_edit_char};

                    if (btn_change_pulse) begin
                        if (curr_edit_char == 8'h5A)
                            curr_edit_char <= 8'h41;
                        else
                            curr_edit_char <= curr_edit_char + 1'b1;
                    end

                    if (btn_next_pulse) begin
                        if (char_idx == 2'd0) name_l0[current_player] <= curr_edit_char;
                        if (char_idx == 2'd1) name_l1[current_player] <= curr_edit_char;
                        if (char_idx == 2'd2) name_l2[current_player] <= curr_edit_char;

                        if (char_idx < 2'd2) begin
                            char_idx       <= char_idx + 1'b1;
                            curr_edit_char <= 8'h41;
                        end else begin
                            char_idx       <= 2'd0;
                            curr_edit_char <= 8'h41;
                            if (current_player < total_players) begin
                                current_player <= current_player + 1'b1;
                            end else begin
                                current_player <= 2'd0;
                                for (k = 0; k < 4; k = k + 1) scores[k] <= 16'd0;
                                game_state <= STATE_GAME_PLAY;
                            end
                        end
                    end
                end

                // 3: JUEGO EN VIVO
                STATE_GAME_PLAY: begin
                    active_name  <= {name_l0[current_player], name_l1[current_player], name_l2[current_player]};
                    active_score <= scores[current_player];

                    if (global_cooldown == 32'd0) begin
                        if (ir_pulses[3]) begin
                            scores[current_player] <= scores[current_player] + 16'd150;
                            score_sfx <= 2'd3;
                            global_cooldown <= 32'd25_000_000;
                        end else if (ir_pulses[2]) begin
                            scores[current_player] <= scores[current_player] + 16'd100;
                            score_sfx <= 2'd2;
                            global_cooldown <= 32'd25_000_000;
                        end else if (ir_pulses[1]) begin
                            scores[current_player] <= scores[current_player] + 16'd100;
                            score_sfx <= 2'd2;
                            global_cooldown <= 32'd25_000_000;
                        end else if (ir_pulses[0]) begin
                            scores[current_player] <= scores[current_player] + 16'd40;
                            score_sfx <= 2'd1;
                            global_cooldown <= 32'd25_000_000;
                        end
                    end

                    if (scores[current_player] >= target_score) begin
                        game_state <= STATE_GAME_WIN;
                        win_sfx <= 1'b1;
                    end

                    if (btn_next_pulse && (total_players > 2'd0)) begin
                        current_player <= (current_player == total_players) ? 2'd0 : current_player + 1'b1;
                    end
                end

                // 4: PANTALLA DE VICTORIA
                STATE_GAME_WIN: begin
                    if (btn_next_pulse || btn_change_pulse) begin
                        game_state <= STATE_SETUP_PLAYERS;
                    end
                end

                default: game_state <= STATE_SETUP_PLAYERS;
            endcase
        end
    end

endmodule

// 5. GENERADOR DE TEXTO LCD 16x2
module lcd_formatter (
    input  wire [2:0]   game_state,
    input  wire [1:0]   total_players,
    input  wire [1:0]   current_player,
    input  wire [23:0]  active_name,
    input  wire [15:0]  active_score,
    input  wire [31:0]  target_ascii,  
    output reg  [127:0] line1_text,
    output reg  [127:0] line2_text
);

    wire [7:0] char_num_p = 8'h31 + total_players;
    wire [7:0] char_jug_n = 8'h31 + current_player;

    wire [7:0] d3 = 8'h30 + ((active_score / 1000) % 10);
    wire [7:0] d2 = 8'h30 + ((active_score / 100) % 10);
    wire [7:0] d1 = 8'h30 + ((active_score / 10) % 10);
    wire [7:0] d0 = 8'h30 + (active_score % 10);

    always @(*) begin
        case (game_state)
            3'd0: begin
                line1_text = {"NUM JUGADORES: ", char_num_p}; 
                line2_text = "CAMB:++   NXT:OK";              
            end
            3'd1: begin
                line1_text = "PUNTAJE LIMITE  ";             
                line2_text = {"PTS: ", target_ascii, " NXT:OK"}; 
            end
            3'd2: begin
                line1_text = "PONGA INICIALES ";       
                line2_text = {"JUG_", char_jug_n, ": [", active_name[23:16], active_name[15:8], active_name[7:0], "]    "}; 
            end
            3'd3: begin
                line1_text = {"TURNO: JUG_", char_jug_n, " ", active_name[23:16], active_name[15:8], active_name[7:0]}; 
                line2_text = {"PTS: ", d3, d2, d1, d0, "       "}; 
            end
            3'd4: begin
                line1_text = {" !GANADOR JUG_", char_jug_n, "!"}; 
                line2_text = {"     [", active_name[23:16], active_name[15:8], active_name[7:0], "]      "}; 
            end
            default: begin
                line1_text = "    BOLIRANA    ";              
                line2_text = "   INICIANDO    ";              
            end
        endcase
    end

endmodule

// 6. CONTROLADOR MAESTRO I2C PARA LCD 16x2

module i2c_lcd_16x2_controller (
    input  wire         clk,
    input  wire         reset_n,
    input  wire [127:0] line1_text,
    input  wire [127:0] line2_text,
    inout  wire         scl,
    inout  wire         sda
);

    parameter [6:0] I2C_ADDR = 7'h27;

    reg scl_out;
    reg sda_out;

    assign scl = (scl_out == 1'b0) ? 1'b0 : 1'bz;
    assign sda = (sda_out == 1'b0) ? 1'b0 : 1'bz;

    reg [8:0] clk_div;
    reg       i2c_tick;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            clk_div  <= 9'd0;
            i2c_tick <= 1'b0;
        end else if (clk_div == 9'd499) begin
            clk_div  <= 9'd0;
            i2c_tick <= 1'b1;
        end else begin
            clk_div  <= clk_div + 1'b1;
            i2c_tick <= 1'b0;
        end
    end

    reg [7:0]  state;
    reg [5:0]  cmd_idx;
    reg        is_rs;
    reg [7:0]  curr_byte;
    reg [31:0] delay_cnt;
    reg [3:0]  bit_idx;
    reg [7:0]  tx_data;
    reg [2:0]  byte_idx;

    wire [7:0] pcf_b0 = {curr_byte[7:4], 1'b1, 1'b1, 1'b0, is_rs};
    wire [7:0] pcf_b1 = {curr_byte[7:4], 1'b1, 1'b0, 1'b0, is_rs};
    wire [7:0] pcf_b2 = {curr_byte[3:0], 1'b1, 1'b1, 1'b0, is_rs};
    wire [7:0] pcf_b3 = {curr_byte[3:0], 1'b1, 1'b0, 1'b0, is_rs};

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state     <= 8'd0;
            scl_out   <= 1'b1;
            sda_out   <= 1'b1;
            cmd_idx   <= 6'd0;
            delay_cnt <= 32'd0;
            bit_idx   <= 4'd0;
            byte_idx  <= 3'd0;
            is_rs     <= 1'b0;
            curr_byte <= 8'h00;
            tx_data   <= 8'h00;
        end else if (i2c_tick) begin
            case (state)
                8'd0: begin
                    scl_out <= 1'b1;
                    sda_out <= 1'b1;
                    if (delay_cnt == 32'd10000) begin
                        delay_cnt <= 32'd0;
                        state     <= 8'd1;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                8'd1: begin
                    case (cmd_idx)
                        6'd0:  begin is_rs <= 0; curr_byte <= 8'h33; end
                        6'd1:  begin is_rs <= 0; curr_byte <= 8'h32; end
                        6'd2:  begin is_rs <= 0; curr_byte <= 8'h28; end
                        6'd3:  begin is_rs <= 0; curr_byte <= 8'h0C; end
                        6'd4:  begin is_rs <= 0; curr_byte <= 8'h01; end
                        6'd5:  begin is_rs <= 0; curr_byte <= 8'h06; end
                        6'd6:  begin is_rs <= 0; curr_byte <= 8'h80; end
                        6'd7:  begin is_rs <= 1; curr_byte <= line1_text[127:120]; end
                        6'd8:  begin is_rs <= 1; curr_byte <= line1_text[119:112]; end
                        6'd9:  begin is_rs <= 1; curr_byte <= line1_text[111:104]; end
                        6'd10: begin is_rs <= 1; curr_byte <= line1_text[103:96];  end
                        6'd11: begin is_rs <= 1; curr_byte <= line1_text[95:88];   end
                        6'd12: begin is_rs <= 1; curr_byte <= line1_text[87:80];   end
                        6'd13: begin is_rs <= 1; curr_byte <= line1_text[79:72];   end
                        6'd14: begin is_rs <= 1; curr_byte <= line1_text[71:64];   end
                        6'd15: begin is_rs <= 1; curr_byte <= line1_text[63:56];   end
                        6'd16: begin is_rs <= 1; curr_byte <= line1_text[55:48];   end
                        6'd17: begin is_rs <= 1; curr_byte <= line1_text[47:40];   end
                        6'd18: begin is_rs <= 1; curr_byte <= line1_text[39:32];   end
                        6'd19: begin is_rs <= 1; curr_byte <= line1_text[31:24];   end
                        6'd20: begin is_rs <= 1; curr_byte <= line1_text[23:16];   end
                        6'd21: begin is_rs <= 1; curr_byte <= line1_text[15:8];    end
                        6'd22: begin is_rs <= 1; curr_byte <= line1_text[7:0];     end
                        6'd23: begin is_rs <= 0; curr_byte <= 8'hC0; end
                        6'd24: begin is_rs <= 1; curr_byte <= line2_text[127:120]; end
                        6'd25: begin is_rs <= 1; curr_byte <= line2_text[119:112]; end
                        6'd26: begin is_rs <= 1; curr_byte <= line2_text[111:104]; end
                        6'd27: begin is_rs <= 1; curr_byte <= line2_text[103:96];  end
                        6'd28: begin is_rs <= 1; curr_byte <= line2_text[95:88];   end
                        6'd29: begin is_rs <= 1; curr_byte <= line2_text[87:80];   end
                        6'd30: begin is_rs <= 1; curr_byte <= line2_text[79:72];   end
                        6'd31: begin is_rs <= 1; curr_byte <= line2_text[71:64];   end
                        6'd32: begin is_rs <= 1; curr_byte <= line2_text[63:56];   end
                        6'd33: begin is_rs <= 1; curr_byte <= line2_text[55:48];   end
                        6'd34: begin is_rs <= 1; curr_byte <= line2_text[47:40];   end
                        6'd35: begin is_rs <= 1; curr_byte <= line2_text[39:32];   end
                        6'd36: begin is_rs <= 1; curr_byte <= line2_text[31:24];   end
                        6'd37: begin is_rs <= 1; curr_byte <= line2_text[23:16];   end
                        6'd38: begin is_rs <= 1; curr_byte <= line2_text[15:8];    end
                        6'd39: begin is_rs <= 1; curr_byte <= line2_text[7:0];     end
                        default: begin is_rs <= 0; curr_byte <= 8'h01; end
                    endcase
                    byte_idx <= 3'd0;
                    state    <= 8'd2;
                end

                8'd2: begin
                    sda_out <= 1'b0;
                    scl_out <= 1'b1;
                    state   <= 8'd3;
                end

                8'd3: begin
                    scl_out  <= 1'b0;
                    tx_data  <= {I2C_ADDR, 1'b0};
                    bit_idx  <= 4'd0;
                    state    <= 8'd4;
                end

                8'd4: begin
                    sda_out <= tx_data[7 - bit_idx[2:0]];
                    state   <= 8'd5;
                end

                8'd5: begin
                    scl_out <= 1'b1;
                    state   <= 8'd6;
                end

                8'd6: begin
                    scl_out <= 1'b0;
                    if (bit_idx == 4'd7) begin
                        sda_out <= 1'b1;
                        state   <= 8'd7;
                    end else begin
                        bit_idx <= bit_idx + 1'b1;
                        state   <= 8'd4;
                    end
                end

                8'd7: begin
                    scl_out <= 1'b1;
                    state   <= 8'd8;
                end

                8'd8: begin
                    scl_out <= 1'b0;
                    state   <= 8'd9;
                end

                8'd9: begin
                    case (byte_idx)
                        3'd0: tx_data <= pcf_b0;
                        3'd1: tx_data <= pcf_b1;
                        3'd2: tx_data <= pcf_b2;
                        3'd3: tx_data <= pcf_b3;
                        default: tx_data <= pcf_b3;
                    endcase
                    bit_idx <= 4'd0;
                    state   <= 8'd10;
                end

                8'd10: begin
                    sda_out <= tx_data[7 - bit_idx[2:0]];
                    state   <= 8'd11;
                end

                8'd11: begin
                    scl_out <= 1'b1;
                    state   <= 8'd12;
                end

                8'd12: begin
                    scl_out <= 1'b0;
                    if (bit_idx == 4'd7) begin
                        sda_out <= 1'd1;
                        state   <= 8'd13;
                    end else begin
                        bit_idx <= bit_idx + 1'b1;
                        state   <= 8'd10;
                    end
                end

                8'd13: begin
                    scl_out <= 1'b1;
                    state   <= 8'd14;
                end

                8'd14: begin
                    scl_out <= 1'b0;
                    if (byte_idx == 3'd3) begin
                        state <= 8'd15;
                    end else begin
                        byte_idx <= byte_idx + 1'b1;
                        state    <= 8'd9;
                    end
                end

                8'd15: begin
                    sda_out <= 1'b0;
                    state   <= 8'd16;
                end

                8'd16: begin
                    scl_out <= 1'b1;
                    state   <= 8'd17;
                end

                8'd17: begin
                    sda_out <= 1'b1;
                    delay_cnt <= 32'd0;
                    state   <= 8'd18;
                end

                8'd18: begin
                    if ((cmd_idx == 6'd4 && delay_cnt == 32'd200) || (cmd_idx != 6'd4 && delay_cnt == 32'd5)) begin
                        delay_cnt <= 32'd0;
                        if (cmd_idx == 6'd39)
                            cmd_idx <= 6'd6;
                        else
                            cmd_idx <= cmd_idx + 1'b1;
                        state <= 8'd1;
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                default: state <= 8'd0;
            endcase
        end
    end
endmodule

module limit_selector (
    input  wire [2:0]  sw_limit,
    output reg  [15:0] target_score,
    output reg  [31:0] target_ascii
);

    // Inversión lógica (~): convierte el estado físico (Active-LOW) a binario natural
    wire [2:0] sw_active = ~sw_limit;

    always @(*) begin
        case (sw_active)
            3'b000: begin target_score = 16'd1000; target_ascii = "1000"; end 
            3'b001: begin target_score = 16'd500;  target_ascii = "0500"; end
            3'b010: begin target_score = 16'd1000; target_ascii = "1000"; end 
            3'b011: begin target_score = 16'd1500; target_ascii = "1500"; end 
            3'b100: begin target_score = 16'd2000; target_ascii = "2000"; end
            3'b101: begin target_score = 16'd2500; target_ascii = "2500"; end 
            3'b110: begin target_score = 16'd3000; target_ascii = "3000"; end 
            3'b111: begin target_score = 16'd3500; target_ascii = "3500"; end 
            default: begin target_score = 16'd1000; target_ascii = "1000"; end
        endcase
    end
endmodule

// 8. BUZZER INTEGRADO A-C4E6E10 (PIN_141)

module bolirana_buzzer (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       btn_change_pulse,
    input  wire       btn_next_pulse,
    input  wire [1:0] score_sfx, // 1=40, 2=100, 3=150
    input  wire       win_sfx,
    output wire       buzzer
);
    reg [2:0]  beeps_left;
    reg        sounding;
    reg [23:0] timer;
    reg [23:0] on_cycles;
    reg [23:0] off_cycles;

    // Transistor de la placa: nivel bajo = sonar, nivel alto = silencio.
    assign buzzer = ~sounding;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            beeps_left <= 3'd0;
            sounding   <= 1'b0;
            timer      <= 24'd0;
            on_cycles  <= 24'd5_000_000;
            off_cycles <= 24'd3_000_000;
        end else if (win_sfx) begin
            // Victoria: 5 pitidos de 130 ms, separados 80 ms.
            beeps_left <= 3'd5;
            sounding   <= 1'b1;
            timer      <= 24'd0;
            on_cycles  <= 24'd6_500_000;
            off_cycles <= 24'd4_000_000;
        end else if (score_sfx != 2'd0) begin
            // 40: 1 pitido. 100: 2 pitidos. 150: 3 pitidos.
            beeps_left <= {1'b0, score_sfx};
            sounding   <= 1'b1;
            timer      <= 24'd0;
            if (score_sfx == 2'd3) begin
                on_cycles  <= 24'd5_500_000; 
                off_cycles <= 24'd3_500_000;
            end else begin
                on_cycles  <= 24'd5_000_000; 
                off_cycles <= 24'd4_000_000; 
            end
        end else if (btn_next_pulse) begin
            // K5 / OK: 2 pitidos de 45 ms.
            beeps_left <= 3'd2;
            sounding   <= 1'b1;
            timer      <= 24'd0;
            on_cycles  <= 24'd2_250_000;
            off_cycles <= 24'd2_250_000;
        end else if (btn_change_pulse) begin
            // K4 / cambio: 1 pitido de 35 ms.
            beeps_left <= 3'd1;
            sounding   <= 1'b1;
            timer      <= 24'd0;
            on_cycles  <= 24'd1_750_000;
            off_cycles <= 24'd1_500_000;
        end else if (sounding) begin
            if (timer >= on_cycles - 1'b1) begin
                sounding   <= 1'b0;
                timer      <= 24'd0;
                beeps_left <= beeps_left - 1'b1;
            end else begin
                timer <= timer + 1'b1;
            end
        end else if (beeps_left != 3'd0) begin
            if (timer >= off_cycles - 1'b1) begin
                sounding <= 1'b1;
                timer    <= 24'd0;
            end else begin
                timer <= timer + 1'b1;
            end
        end else begin
            timer <= 24'd0;
        end
    end
endmodule
