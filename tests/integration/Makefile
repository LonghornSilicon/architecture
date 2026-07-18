# End-to-end cosim: KVCE + APA + TIU (three block repos, assumed cloned as siblings).
IVERILOG ?= iverilog
VVP      ?= vvp
LHS      ?= ../../..
KVCE_RTL := $(LHS)/kv-cache-engine/rtl
APA_RTL  := $(LHS)/adaptive-precision-attention/rtl
TIU_RTL  := $(LHS)/token-importance-unit/rtl

KVCE_SRC := $(KVCE_RTL)/cq_value_path.sv $(KVCE_RTL)/amax_unit.sv \
            $(KVCE_RTL)/cq_fp_pkg.sv $(KVCE_RTL)/cq_units.sv $(KVCE_RTL)/cq_units_syn.sv
APA_SRC  := $(APA_RTL)/precision_controller.sv
TIU_SRC  := $(TIU_RTL)/token_importance_unit.sv

.PHONY: sim clean
sim: build/tb_e2e
	$(VVP) build/tb_e2e

build/tb_e2e: tb_kvce_apa_tiu.sv $(KVCE_SRC) $(APA_SRC) $(TIU_SRC)
	@mkdir -p build
	$(IVERILOG) -g2012 -I $(KVCE_RTL) -o build/tb_e2e $(KVCE_SRC) $(APA_SRC) $(TIU_SRC) tb_kvce_apa_tiu.sv

clean:
	rm -rf build
