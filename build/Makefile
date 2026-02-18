OUTPUT_DIR?=output

kintex:
	OUTPUT_DIR=${OUTPUT_DIR} TARGET=kintex vivado -notrace -nojournal -nolog -mode batch -source gen_bitstream.tcl

nexys:
	OUTPUT_DIR=${OUTPUT_DIR} TARGET=nexys vivado -notrace -nojournal -nolog -mode batch -source gen_bitstream.tcl

clean:
	rm -rf ${OUTPUT_DIR}
