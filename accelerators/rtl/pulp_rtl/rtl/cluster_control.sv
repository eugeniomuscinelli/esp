module cluster_control (
    input logic          clk,
    input logic          rst_n,
    input logic          conf_done,
    input logic [31:0]   reg_0,
    input logic [31:0]   reg_1,
    input logic [31:0]   reg_2,
    input logic [31:0]   reg_3,
    input logic [31:0]   target_addresses [0:3],
    output logic         fetch_enable,
    output logic         boot_enable,
    output logic         acc_done,
    
    // AXI slave interface
    AXI_BUS.Slave axi_slave,
    input  logic         eoc
);

  typedef enum logic [2:0] {
    IDLE,
    WRITE_ADDR,
    WRITE_DATA,
    WAIT_COMPUTE,
    DONE
  } state_t;

  state_t state, next_state;

  // Register array to hold different configuration registers
  logic [31:0] config_registers [0:3];

  // Index for address configuration
  logic [1:0] config_index;

  // Sequential state transition
  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      state <= IDLE;

    end else begin

      state <= next_state;

    end

  end

  // Combinational next state logic and output logic
  always_comb begin
    // Default values
    next_state = state;
    axi_slave.aw_valid = 0;
    axi_slave.w_valid = 0;
    axi_slave.aw_addr = 0;
    axi_slave.aw_len = 0;
    axi_slave.aw_size = 3'b010; // Word size
    axi_slave.aw_burst = 2'b01; // INCR burst
    axi_slave.w_data = 0;
    axi_slave.w_strb = {axi_slave.AXI_STRB_WIDTH{1'b1}}; // Writing full word
    axi_slave.w_last = 0;
    fetch_enable = 0;
    boot_enable = 0;
    acc_done = 0;
    axi_slave.b_ready = 1;
    config_index = 0;

    config_registers[0] = reg_0;
    config_registers[1] = reg_1;
    config_registers[2] = reg_2;
    config_registers[3] = reg_3;

    case (state)

      IDLE: begin

        if (conf_done) begin

          config_index = 0;
          next_state = WRITE_ADDR;

        end

      end

      WRITE_ADDR: begin

        // Initiate write address phase for each register
        if (config_index < 4) begin

          axi_slave.aw_valid = 1;
          axi_slave.aw_addr = target_addresses[config_index]; 
          axi_slave.aw_len = 0; 

          if (axi_slave.aw_ready) begin

            axi_slave.aw_valid = 0;
            next_state = WRITE_DATA;

          end

        end

      end

      WRITE_DATA: begin

        axi_slave.w_valid = 1;
        axi_slave.w_data = config_registers[config_index];
        axi_slave.w_last = 1; 

        if (axi_slave.w_ready) begin
          axi_slave.w_valid = 0;
          axi_slave.w_last = 0;
          config_index = config_index + 1;

          if (config_index < 4) begin

            next_state = WRITE_ADDR;

          end else begin

            fetch_enable = 1;
            boot_enable = 1;
            next_state = WAIT_COMPUTE;

          end

        end

      end

      WAIT_COMPUTE: begin

        if (eoc) begin

          next_state = DONE;

        end

      end

      DONE: begin

        acc_done = 1;
        next_state = IDLE;

      end

    endcase

  end

endmodule