make_release_only()

set( CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DZ7_PPMD_SUPPORT" )

find_package(Threads)

set(LZMA_SOURCES
	C/7zAlloc.c
	C/7zArcIn.c
	C/7zBuf.c
	C/7zBuf2.c
	C/7zCrc.c
	C/7zCrcOpt.c
	C/7zDec.c
	C/7zFile.c
	C/7zStream.c
	C/Alloc.c
	C/Bcj2.c
	C/Bcj2Enc.c
	C/Bra.c
	C/Bra86.c
	C/CpuArch.c
	C/Delta.c
	C/DllSecur.c
	C/LzFind.c
	C/LzFindMt.c
	C/LzFindOpt.c
	C/Lzma2Dec.c
	C/Lzma2DecMt.c
	C/Lzma2Enc.c
	C/LzmaDec.c
	C/LzmaEnc.c
	C/LzmaLib.c
	C/MtCoder.c
	C/MtDec.c
	C/Ppmd7.c
	C/Ppmd7Dec.c
	C/Ppmd7Enc.c
	C/Sha256.c
	C/Sha256Opt.c
	C/Sort.c
	C/SwapBytes.c
	C/Threads.c
	C/Xz.c
	C/XzCrc64.c
	C/XzCrc64Opt.c
	C/XzDec.c
	C/XzEnc.c
	C/XzIn.c
)

if( EMSCRIPTEN OR NOT Threads_FOUND )
	list(REMOVE_ITEM LZMA_SOURCES
		C/LzFindMt.c
		C/Lzma2DecMt.c
		C/MtCoder.c
		C/MtDec.c
		C/Threads.c
	)
endif()

add_library( lzma STATIC ${LZMA_SOURCES} )
if( EMSCRIPTEN OR NOT Threads_FOUND )
	target_compile_definitions( lzma PRIVATE Z7_ST )
endif()
if( Threads_FOUND )
	target_link_libraries( lzma Threads::Threads )
endif()
