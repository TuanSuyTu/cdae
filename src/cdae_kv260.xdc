# ==========================================================
# File: cdae_kv260.xdc
# Purpose:
#   File rang buoc (Constraints) cho kit KV260 SOM.
#   Cau hinh xung nhip 200MHz va bo qua kiem tra Timing
#   (false path) doi voi cac tin hieu dieu khien AXI async.
# ==========================================================

# Xung nhip 200 MHz tu PS
create_clock -period 5.000 -name pl_clk0 [get_pins -hierarchical -filter {NAME =~ */pl_clk0}]

# Bo qua timing cho tin hieu dieu khien bat dong bo tu PS
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *start_pulse*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ *fsm_inst/state*}]

# Bo qua timing cho tin hieu bao cao trang thai ve PS
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *done_inference*}]
