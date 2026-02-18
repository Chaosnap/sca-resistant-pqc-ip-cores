set OUTPUT_DIR $env(OUTPUT_DIR)
set TARGET $env(TARGET)

file mkdir $OUTPUT_DIR

read_vhdl -vhdl2008 [glob ../*.vhd]
read_vhdl -vhdl2008 [glob ../masking/*.vhd]
read_vhdl -vhdl2008 [glob ../util_comps/*.vhd]

switch -- $TARGET {
    kintex {
        set PART "xc7k160tfbg676-1"
        set GENERIC "UART_CYCLES_PER_BIT=6"
        read_xdc ../constraints/kintex.xdc
    }
    nexys {
        set PART "xc7a100tcsg324-1"
        set GENERIC "UART_CYCLES_PER_BIT=868"
        read_xdc ../constraints/nexys.xdc
    }
    default {
        error "Unknown TARGET '$TARGET'! Expected {kintext | nexys }"
    }
}

# run synthesis
synth_design -top wrapper -part $PART -generic $GENERIC
write_checkpoint -force $OUTPUT_DIR/post_synth.dcp

# run implementation
opt_design
place_design
write_checkpoint -force $OUTPUT_DIR/post_place.dcp

route_design
write_checkpoint -force $OUTPUT_DIR/post_route.dcp

# generate bitstream
write_bitstream -force $OUTPUT_DIR/$TARGET.bit
