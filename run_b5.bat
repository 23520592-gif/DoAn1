@echo off
REM ============================================================
REM run_b5.bat - Chay mo phong B5 truc tiep bang xsim (khong qua GUI project)
REM Dat file nay o E:\DoAn1 va chay tu "cmd" trong thu muc do.
REM Yeu cau: da chay settings64.bat cua Vivado, hoac dung Vivado Tcl shell.
REM ============================================================
setlocal

REM --- Duong dan Vivado (sua neu khac) ---
set XVLOG=G:\Vivado\2025.2\Vivado\bin\xvlog.bat
set XELAB=G:\Vivado\2025.2\Vivado\bin\xelab.bat
set XSIM=G:\Vivado\2025.2\Vivado\bin\xsim.bat

REM --- Include dirs (cho prim_assert.sv va cac .svh) ---
set INC=-i E:/DoAn1/ibex/rtl -i E:/DoAn1/ibex/vendor/lowrisc_ip/ip/prim/rtl -i E:/DoAn1/ibex/vendor/lowrisc_ip/ip/prim_generic/rtl -i E:/DoAn1/ibex/vendor/lowrisc_ip/dv/sv/dv_utils

echo ========== BUOC 1: COMPILE (xvlog) ==========
call %XVLOG% --relax -sv -d SYNTHESIS -prj E:/DoAn1/ibex_v3.prj %INC% -L uvm
if errorlevel 1 ( echo COMPILE FAILED & exit /b 1 )

echo ========== BUOC 2: ELABORATE (xelab) ==========
call %XELAB% --relax --debug typical --mt 2 -L xil_defaultlib -L uvm -L unisims_ver -L unimacro_ver -L secureip --snapshot v3_snap xil_defaultlib.ibex_dualcore_v3_tb xil_defaultlib.glbl
if errorlevel 1 ( echo ELABORATE FAILED & exit /b 1 )

echo ========== BUOC 3: SIMULATE (xsim) ==========
REM Chay khong GUI, tu finish theo $finish trong testbench
call %XSIM% v3_snap -gui

echo ========== XONG ==========
endlocal
