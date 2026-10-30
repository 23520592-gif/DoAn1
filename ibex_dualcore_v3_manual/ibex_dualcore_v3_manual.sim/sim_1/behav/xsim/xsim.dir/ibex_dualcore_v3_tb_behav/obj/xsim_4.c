/**********************************************************************/
/*   ____  ____                                                       */
/*  /   /\/   /                                                       */
/* /___/  \  /                                                        */
/* \   \   \/                                                         */
/*  \   \        Copyright (c) 2003-2020 Xilinx, Inc.                 */
/*  /   /        All Right Reserved.                                  */
/* /---/   /\                                                         */
/* \   \  /  \                                                        */
/*  \___\/\___\                                                       */
/**********************************************************************/

#if defined(_WIN32)
 #include "stdio.h"
 #define IKI_DLLESPEC __declspec(dllimport)
#else
 #define IKI_DLLESPEC
#endif
#include "iki.h"
#include <string.h>
#include <math.h>
#ifdef __GNUC__
#include <stdlib.h>
#else
#include <malloc.h>
#define alloca _alloca
#endif
#include "svdpi.h"
#include <cstring>


#if (defined(_MSC_VER) || defined(__MINGW32__) || defined(__CYGWIN__))
#define DPI_DLLISPEC __declspec(dllimport)
#define DPI_DLLESPEC __declspec(dllexport)
#else
#define DPI_DLLISPEC
#define DPI_DLLESPEC
#endif


extern "C"
{
	DPI_DLLISPEC extern void  DPISetMode(int mode) ;
	DPI_DLLISPEC extern int   DPIGetMode() ; 
	DPI_DLLISPEC extern void  DPIAllocateExportedFunctions(int size) ;
	DPI_DLLISPEC extern void  DPIAddExportedFunction(int index, const char* value) ;
	DPI_DLLISPEC extern void  DPIAllocateSVCallerName(int index, const char* y) ;
	DPI_DLLISPEC extern void  DPISetCallerName(int index, const char* y) ;
	DPI_DLLISPEC extern void  DPISetCallerLine(int index, unsigned int y) ;
	DPI_DLLISPEC extern void  DPISetCallerOffset(int index, int y) ;
	DPI_DLLISPEC extern void  DPIAllocateDPIScopes(int size) ;
	DPI_DLLISPEC extern void  DPISetDPIScopeFunctionName(int index, const char* y) ;
	DPI_DLLISPEC extern void  DPISetDPIScopeHierarchy(int index, const char* y) ;
	DPI_DLLISPEC extern void  DPIRelocateDPIScopeIP(int index, char* IP) ;
	DPI_DLLISPEC extern void  DPIAddDPIScopeAccessibleFunction(int index, unsigned int y) ;
	DPI_DLLISPEC extern void  DPIFlushAll() ;
	DPI_DLLISPEC extern void  DPIVerifyScope() ;
	DPI_DLLISPEC extern char* DPISignalHandle(char* sigHandle, int length) ;
	DPI_DLLISPEC extern char* DPIMalloc(unsigned noOfBytes) ;
	DPI_DLLISPEC extern void  DPITransactionAuto(char* srcValue, unsigned int startIndex, unsigned int endIndex, char* net) ;
	DPI_DLLISPEC extern void  DPIScheduleTransactionBlocking(char* var, char* driver, char* src, unsigned setback, unsigned lenMinusOnne) ;
	DPI_DLLISPEC extern void  DPIMemsetSvToDpi(char* dst, char* src, int numCBytes, int is2state) ;
	DPI_DLLISPEC extern void  DPIMemsetDpiToSv(char* dst, char* src, int numCBytes, int is2state) ;
	DPI_DLLISPEC extern void  DPIMemsetSvLogic1ToDpi(char* dst, char* src) ;
	DPI_DLLISPEC extern void  DPIMemsetDpiToSvLogic1(char* dst, char* src) ;
	DPI_DLLISPEC extern void  DPIMemsetDpiToSvUnpackedLogic(char* dst, char* src, int* numRshift, int* shift) ;
	DPI_DLLISPEC extern void  DPIMemsetDpiToSvUnpackedLogicWithPackedDim(char* dst, char* src, int pckedSz, int* numRshift, int* shift) ;
	DPI_DLLISPEC extern void  DPIMemsetSvToDpiUnpackedLogic(char* dst, char* src, int* numRshift, int* shift) ;
	DPI_DLLISPEC extern void  DPIMemsetSvToDpiUnpackedLogicWithPackedDim(char* dst, char* src, int pckdSz, int* numRshift, int* shift) ;
	DPI_DLLISPEC extern void  DPIMemsetDpiToSvUnpackedBit(char* dst, char* src, int* numRshift, int* shift) ;
	DPI_DLLISPEC extern void  DPIMemsetDpiToSvUnpackedBitWithPackedDim(char* dst, char* src, int pckdSz, int* numRshift, int* shift) ;
	DPI_DLLISPEC extern void  DPIMemsetSvToDpiUnpackedBit(char* dst, char* src, int* numRshift, int* shift) ;
	DPI_DLLISPEC extern void  DPIMemsetSvToDpiUnpackedBitWithPackedDim(char* dst, char* src, int pckdSz, int* numRshift, int* shift) ;
	DPI_DLLISPEC extern void  DPISetFuncName(const char* funcName) ;
	DPI_DLLISPEC extern int   staticScopeCheck(const char* calledFunction) ;
	DPI_DLLISPEC extern void  DPIAllocateSVCallerInfo(int size) ;
	DPI_DLLISPEC extern void* DPICreateContext(int scopeId, char* IP, int callerIdx);
	DPI_DLLISPEC extern void* DPIGetCurrentContext();
	DPI_DLLISPEC extern void  DPISetCurrentContext(void*);
	DPI_DLLISPEC extern void  DPIRemoveContext(void*);
	DPI_DLLISPEC extern int   svGetScopeStaticId();
	DPI_DLLISPEC extern char* svGetScopeIP();
	DPI_DLLISPEC extern unsigned DPIGetUnpackedSizeFromSVOpenArray(svOpenArray*);
	DPI_DLLISPEC extern unsigned DPIGetConstraintSizeFromSVOpenArray(svOpenArray*, int);
	DPI_DLLISPEC extern int   topOffset() ;
	DPI_DLLISPEC extern char* DPIInitializeFunction(char* p, unsigned size, long long offset) ;
	DPI_DLLISPEC extern void  DPIInvokeFunction(char* processPtr, char* SP, void* func, char* IP) ;
	DPI_DLLISPEC extern void  DPIDeleteFunctionInvocation(char* SP) ;
	DPI_DLLISPEC extern void  DPISetTaskScopeId(int scopeId) ;
	DPI_DLLISPEC extern void  DPISetTaskCaller(int index) ;
	DPI_DLLISPEC extern int   DPIGetTaskCaller() ;
	DPI_DLLISPEC extern char* DPIInitializeTask(long long subprogInDPOffset, char* scopePropInIP, unsigned size, char* parentBlock) ;
	DPI_DLLISPEC extern void  DPIInvokeTask(long long subprogInDPOffset, char* SP, void* func, char* IP) ;
	DPI_DLLISPEC extern void  DPIDeleteTaskInvocation(char* SP) ;
	DPI_DLLISPEC extern void* DPICreateTaskContext(int (*wrapper)(char*, char*, char*), char* DP, char* IP, char* SP, size_t stackSz) ;
	DPI_DLLISPEC extern void  DPIRemoveTaskContext(void*) ;
	DPI_DLLISPEC extern void  DPICallCurrentContext() ;
	DPI_DLLISPEC extern void  DPIYieldCurrentContext() ;
	DPI_DLLISPEC extern void* DPIGetCurrentTaskContext() ;
	DPI_DLLISPEC extern int   DPIRunningInNewContext() ;
	DPI_DLLISPEC extern void  DPISetCurrentTaskContext(void* x) ;
}

namespace XILINX_DPI { 

	void dpiInitialize()
	{
		DPIAllocateExportedFunctions(2) ;
		DPIAddExportedFunction(0, "gen_prefetch_buffer.simutil_get_scramble_key") ;
		DPIAddExportedFunction(1, "gen_prefetch_buffer.simutil_get_scramble_nonce") ;
		DPIAllocateDPIScopes(4) ;
		DPISetDPIScopeFunctionName(0, "gen_prefetch_buffer.simutil_get_scramble_key") ;
		DPISetDPIScopeHierarchy(0, "ibex_dualcore_v3_tb.u_dut.u_core0.u_ibex_core.if_stage_i") ;
		DPIRelocateDPIScopeIP(0, (char*)(0xbd6e0)) ;
		DPIAddDPIScopeAccessibleFunction(0, 0) ;
		DPIAddDPIScopeAccessibleFunction(0, 1) ;
		DPISetDPIScopeFunctionName(1, "gen_prefetch_buffer.simutil_get_scramble_key") ;
		DPISetDPIScopeHierarchy(1, "ibex_dualcore_v3_tb.u_dut.u_core1.u_ibex_core.if_stage_i") ;
		DPIRelocateDPIScopeIP(1, (char*)(0x12d400)) ;
		DPIAddDPIScopeAccessibleFunction(1, 0) ;
		DPIAddDPIScopeAccessibleFunction(1, 1) ;
	}

}


extern "C" {
	void iki_initialize_dpi()
	{ XILINX_DPI::dpiInitialize() ; } 
}


extern "C" {

	extern void subprog_m_a149cf2_d6bbf7e1_4(char*, char*, char*);
	extern void subprog_m_a149cf2_d6bbf7e1_3(char*, char*, char*);
}


extern "C" {
}


extern "C" {
	DPI_DLLESPEC 
	int gen_prefetch_buffer.simutil_get_scramble_key(svBitVecVal arg0[SV_PACKED_DATA_NELEMS(128)])
	{
		int result ;
		DPIVerifyScope();
		int functionToCall = staticScopeCheck("gen_prefetch_buffer.simutil_get_scramble_key") ;
		switch(functionToCall)
		{
			case 0:
			{

	{
		fflush(stdout); fflush(stderr);
		int staticIndex = 0 ;
		char* IP = NULL ;
		staticIndex = svGetScopeStaticId() ;
		IP = svGetScopeIP();
		int callingProcessOffset = topOffset() ;
		char* SP ;
		void* oldSPcontext = DPIGetCurrentContext();
		SP = DPIInitializeFunction(IP + 24792, 804, 587280) ;
		char* oldSP = *((char**)(IP + callingProcessOffset + 80)) ; 
		DPIInvokeFunction(IP + callingProcessOffset, SP, (void*)(subprog_m_a149cf2_d6bbf7e1_3), IP) ;
		{
		char* ptrToSP = (char*)SP + 736;
		DPIMemsetSvToDpi( (char*)arg0, ptrToSP, 16, 1 );
		}
		char* resultPtr ;
		resultPtr = SP + 544 ;
		result = *((int*)resultPtr) ;
		DPIDeleteFunctionInvocation(SP) ;
		*((char**)(IP + callingProcessOffset + 80)) = oldSP ; 
		DPISetCurrentContext(oldSPcontext);
		fflush(stdout); fflush(stderr); 
	}
			}
			break ;
			default:
			break ;
		}
		return result ;
	}
	DPI_DLLESPEC 
	int gen_prefetch_buffer.simutil_get_scramble_nonce(svBitVecVal arg0[SV_PACKED_DATA_NELEMS(320)])
	{
		int result ;
		DPIVerifyScope();
		int functionToCall = staticScopeCheck("gen_prefetch_buffer.simutil_get_scramble_nonce") ;
		switch(functionToCall)
		{
			case 1:
			{

	{
		fflush(stdout); fflush(stderr);
		int staticIndex = 0 ;
		char* IP = NULL ;
		staticIndex = svGetScopeStaticId() ;
		IP = svGetScopeIP();
		int callingProcessOffset = topOffset() ;
		char* SP ;
		void* oldSPcontext = DPIGetCurrentContext();
		SP = DPIInitializeFunction(IP + 24840, 852, 590080) ;
		char* oldSP = *((char**)(IP + callingProcessOffset + 80)) ; 
		DPIInvokeFunction(IP + callingProcessOffset, SP, (void*)(subprog_m_a149cf2_d6bbf7e1_4), IP) ;
		{
		char* ptrToSP = (char*)SP + 736;
		DPIMemsetSvToDpi( (char*)arg0, ptrToSP, 40, 1 );
		}
		char* resultPtr ;
		resultPtr = SP + 544 ;
		result = *((int*)resultPtr) ;
		DPIDeleteFunctionInvocation(SP) ;
		*((char**)(IP + callingProcessOffset + 80)) = oldSP ; 
		DPISetCurrentContext(oldSPcontext);
		fflush(stdout); fflush(stderr); 
	}
			}
			break ;
			default:
			break ;
		}
		return result ;
	}
}

