;*****************************************************************************
;* quant-a.asm: x86 quantization and level-run
;*****************************************************************************
;* Copyright (C) 2005-2013 x264 project
;*
;* Authors: Loren Merritt <lorenm@u.washington.edu>
;*          Jason Garrett-Glaser <darkshikari@gmail.com>
;*          Christian Heine <sennindemokrit@gmx.net>
;*          Oskar Arvidsson <oskar@irock.se>
;*          Henrik Gramner <hengar-6@student.ltu.se>
;*
;* This program is free software; you can redistribute it and/or modify
;* it under the terms of the GNU General Public License as published by
;* the Free Software Foundation; either version 2 of the License, or
;* (at your option) any later version.
;*
;* This program is distributed in the hope that it will be useful,
;* but WITHOUT ANY WARRANTY; without even the implied warranty of
;* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;* GNU General Public License for more details.
;*
;* You should have received a copy of the GNU General Public License
;* along with this program; if not, write to the Free Software
;* Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02111, USA.
;*
;* This program is also available under a commercial proprietary license.
;* For more information, contact us at licensing@x264.com.
;*****************************************************************************

%include "x86inc.asm"
%include "x86util.asm"

SECTION_RODATA

%macro DQM4 3
    dw %1, %2, %1, %2, %2, %3, %2, %3
%endmacro
%macro DQM8 6
    dw %1, %4, %5, %4, %1, %4, %5, %4
    dw %4, %2, %6, %2, %4, %2, %6, %2
    dw %5, %6, %3, %6, %5, %6, %3, %6
    ; last line not used, just padding for power-of-2 stride
    times 8 dw 0
%endmacro

dequant4_scale:
    DQM4 10, 13, 16
    DQM4 11, 14, 18
    DQM4 13, 16, 20
    DQM4 14, 18, 23
    DQM4 16, 20, 25
    DQM4 18, 23, 29

dequant8_scale:
    DQM8 20, 18, 32, 19, 25, 24
    DQM8 22, 19, 35, 21, 28, 26
    DQM8 26, 23, 42, 24, 33, 31
    DQM8 28, 25, 45, 26, 35, 33
    DQM8 32, 28, 51, 30, 40, 38
    DQM8 36, 32, 58, 34, 46, 43

decimate_mask_table4:
    db  0,3,2,6,2,5,5,9,1,5,4,8,5,8,8,12,1,4,4,8,4,7,7,11,4,8,7,11,8,11,11,15,1,4
    db  3,7,4,7,7,11,3,7,6,10,7,10,10,14,4,7,7,11,7,10,10,14,7,11,10,14,11,14,14
    db 18,0,4,3,7,3,6,6,10,3,7,6,10,7,10,10,14,3,6,6,10,6,9,9,13,6,10,9,13,10,13
    db 13,17,4,7,6,10,7,10,10,14,6,10,9,13,10,13,13,17,7,10,10,14,10,13,13,17,10
    db 14,13,17,14,17,17,21,0,3,3,7,3,6,6,10,2,6,5,9,6,9,9,13,3,6,6,10,6,9,9,13
    db  6,10,9,13,10,13,13,17,3,6,5,9,6,9,9,13,5,9,8,12,9,12,12,16,6,9,9,13,9,12
    db 12,16,9,13,12,16,13,16,16,20,3,7,6,10,6,9,9,13,6,10,9,13,10,13,13,17,6,9
    db  9,13,9,12,12,16,9,13,12,16,13,16,16,20,7,10,9,13,10,13,13,17,9,13,12,16
    db 13,16,16,20,10,13,13,17,13,16,16,20,13,17,16,20,17,20,20,24

chroma_dc_dct_mask_mmx: dw 0, 0,-1,-1, 0, 0,-1,-1
chroma_dc_dmf_mask_mmx: dw 0, 0,-1,-1, 0,-1,-1, 0
chroma_dc_dct_mask:     dw 1, 1,-1,-1, 1, 1,-1,-1
chroma_dc_dmf_mask:     dw 1, 1,-1,-1, 1,-1,-1, 1

SECTION .text

cextern pb_1
cextern pw_1
cextern pd_1
cextern pb_01
cextern pd_1024

%macro QUANT_DC_START 0
    movd       m6, r1m     ; mf
    movd       m7, r2m     ; bias
%if HIGH_BIT_DEPTH
    SPLATD     m6, m6
    SPLATD     m7, m7
%elif cpuflag(sse4) ; ssse3, but not faster on conroe
    mova       m5, [pb_01]
    pshufb     m6, m5
    pshufb     m7, m5
%else
    SPLATW     m6, m6
    SPLATW     m7, m7
%endif
%endmacro

%macro QUANT_END 0
    xor      eax, eax
%if cpuflag(sse4)
    ptest     m5, m5
%else ; !sse4
%if ARCH_X86_64
%if mmsize == 16
    packsswb  m5, m5
%endif
    movq     rcx, m5
    test     rcx, rcx
%else
%if mmsize == 16
    pxor      m4, m4
    pcmpeqb   m5, m4
    pmovmskb ecx, m5
    cmp      ecx, (1<<mmsize)-1
%else
    packsswb  m5, m5
    movd     ecx, m5
    test     ecx, ecx
%endif
%endif
%endif ; cpuflag
    setne     al
%endmacro

%if HIGH_BIT_DEPTH
%macro QUANT_ONE_DC 4
%if cpuflag(sse4)
    mova        m0, [%1]
    ABSD        m1, m0
    paddd       m1, %3
    pmulld      m1, %2
    psrad       m1, 16
%else ; !sse4
    mova        m0, [%1]
    ABSD        m1, m0
    paddd       m1, %3
    mova        m2, m1
    psrlq       m2, 32
    pmuludq     m1, %2
    pmuludq     m2, %2
    psllq       m2, 32
    paddd       m1, m2
    psrld       m1, 16
%endif ; cpuflag
    PSIGND      m1, m0
    mova      [%1], m1
    ACCUM     por, 5, 1, %4
%endmacro

%macro QUANT_TWO_DC 4
%if cpuflag(sse4)
    mova        m0, [%1       ]
    mova        m1, [%1+mmsize]
    ABSD        m2, m0
    ABSD        m3, m1
    paddd       m2, %3
    paddd       m3, %3
    pmulld      m2, %2
    pmulld      m3, %2
    psrad       m2, 16
    psrad       m3, 16
    PSIGND      m2, m0
    PSIGND      m3, m1
    mova [%1       ], m2
    mova [%1+mmsize], m3
    ACCUM      por, 5, 2, %4
    por         m5, m3
%else ; !sse4
    QUANT_ONE_DC %1, %2, %3, %4
    QUANT_ONE_DC %1+mmsize, %2, %3, %4+mmsize
%endif ; cpuflag
%endmacro

%macro QUANT_ONE_AC_MMX 5
    mova        m0, [%1]
    mova        m2, [%2]
    ABSD        m1, m0
    mova        m4, m2
    paddd       m1, [%3]
    mova        m3, m1
    psrlq       m4, 32
    psrlq       m3, 32
    pmuludq     m1, m2
    pmuludq     m3, m4
    psllq       m3, 32
    paddd       m1, m3
    psrad       m1, 16
    PSIGND      m1, m0
    mova      [%1], m1
    ACCUM      por, %5, 1, %4
%endmacro

%macro QUANT_TWO_AC 5
%if cpuflag(sse4)
    mova        m0, [%1       ]
    mova        m1, [%1+mmsize]
    ABSD        m2, m0
    ABSD        m3, m1
    paddd       m2, [%3       ]
    paddd       m3, [%3+mmsize]
    pmulld      m2, [%2       ]
    pmulld      m3, [%2+mmsize]
    psrad       m2, 16
    psrad       m3, 16
    PSIGND      m2, m0
    PSIGND      m3, m1
    mova [%1       ], m2
    mova [%1+mmsize], m3
    ACCUM      por, %5, 2, %4
    ACCUM      por, %5, 3, %4+mmsize
%else ; !sse4
    QUANT_ONE_AC_MMX %1, %2, %3, %4, %5
    QUANT_ONE_AC_MMX %1+mmsize, %2+mmsize, %3+mmsize, %4+mmsize, %5
%endif ; cpuflag
%endmacro

;-----------------------------------------------------------------------------
; int quant_2x2( int32_t dct[M*N], int mf, int bias )
;-----------------------------------------------------------------------------
%macro QUANT_DC 2
cglobal quant_%1x%2_dc, 3,3,8
    QUANT_DC_START
%if %1*%2 <= mmsize/4
    QUANT_ONE_DC r0, m6, m7, 0
%else
%assign x 0
%rep %1*%2/(mmsize/2)
    QUANT_TWO_DC r0+x, m6, m7, x
%assign x x+mmsize*2
%endrep
%endif
    QUANT_END
    RET
%endmacro

;-----------------------------------------------------------------------------
; int quant_MxN( int32_t dct[M*N], uint32_t mf[M*N], uint32_t bias[M*N] )
;-----------------------------------------------------------------------------
%macro QUANT_AC 2
cglobal quant_%1x%2, 3,3,8
%assign x 0
%rep %1*%2/(mmsize/2)
    QUANT_TWO_AC r0+x, r1+x, r2+x, x, 5
%assign x x+mmsize*2
%endrep
    QUANT_END
    RET
%endmacro

%macro QUANT_4x4 2
    QUANT_TWO_AC r0+%1+mmsize*0, r1+mmsize*0, r2+mmsize*0, mmsize*0, %2
    QUANT_TWO_AC r0+%1+mmsize*2, r1+mmsize*2, r2+mmsize*2, mmsize*2, %2
%endmacro

%macro QUANT_4x4x4 0
cglobal quant_4x4x4, 3,3,8
    QUANT_4x4  0, 5
    QUANT_4x4 64, 6
    add       r0, 128
    packssdw  m5, m6
    QUANT_4x4  0, 6
    QUANT_4x4 64, 7
    packssdw  m6, m7
    packssdw  m5, m6
    packssdw  m5, m5  ; AA BB CC DD
    packsswb  m5, m5  ; A B C D
    pxor      m4, m4
    pcmpeqb   m5, m4
    pmovmskb eax, m5
    not      eax
    and      eax, 0xf
    RET
%endmacro

INIT_XMM sse2
QUANT_DC 2, 2
QUANT_DC 4, 4
QUANT_AC 4, 4
QUANT_AC 8, 8
QUANT_4x4x4

INIT_XMM ssse3
QUANT_DC 2, 2
QUANT_DC 4, 4
QUANT_AC 4, 4
QUANT_AC 8, 8
QUANT_4x4x4

INIT_XMM sse4
QUANT_DC 2, 2
QUANT_DC 4, 4
QUANT_AC 4, 4
QUANT_AC 8, 8
QUANT_4x4x4

%endif ; HIGH_BIT_DEPTH

%if HIGH_BIT_DEPTH == 0
%macro QUANT_ONE 4
;;; %1      (m64)       dct[y][x]
;;; %2      (m64/mmx)   mf[y][x] or mf[0][0] (as uint16_t)
;;; %3      (m64/mmx)   bias[y][x] or bias[0][0] (as uint16_t)
    mova       m1, %1   ; load dct coeffs
    ABSW       m0, m1, sign
    paddusw    m0, %3   ; round
    pmulhuw    m0, %2   ; divide
    PSIGNW     m0, m1   ; restore sign
    mova       %1, m0   ; store
    ACCUM     por, 5, 0, %4
%endmacro

%macro QUANT_TWO 8
    mova       m1, %1
    mova       m3, %2
    ABSW       m0, m1, sign
    ABSW       m2, m3, sign
    paddusw    m0, %5
    paddusw    m2, %6
    pmulhuw    m0, %3
    pmulhuw    m2, %4
    PSIGNW     m0, m1
    PSIGNW     m2, m3
    mova       %1, m0
    mova       %2, m2
    ACCUM     por, %8, 0, %7
    ACCUM     por, %8, 2, %7+mmsize
%endmacro

;-----------------------------------------------------------------------------
; void quant_4x4_dc( int16_t dct[16], int mf, int bias )
;-----------------------------------------------------------------------------
%macro QUANT_DC 2-3 0
cglobal %1, 1,1,%3
    QUANT_DC_START
%if %2==1
    QUANT_ONE [r0], m6, m7, 0
%else
%assign x 0
%rep %2/2
    QUANT_TWO [r0+x], [r0+x+mmsize], m6, m6, m7, m7, x, 5
%assign x x+mmsize*2
%endrep
%endif
    QUANT_END
    RET
%endmacro

;-----------------------------------------------------------------------------
; int quant_4x4( int16_t dct[16], uint16_t mf[16], uint16_t bias[16] )
;-----------------------------------------------------------------------------
%macro QUANT_AC 2
cglobal %1, 3,3
%assign x 0
%rep %2/2
    QUANT_TWO [r0+x], [r0+x+mmsize], [r1+x], [r1+x+mmsize], [r2+x], [r2+x+mmsize], x, 5
%assign x x+mmsize*2
%endrep
    QUANT_END
    RET
%endmacro

%macro QUANT_4x4 2
%if UNIX64
    QUANT_TWO [r0+%1+mmsize*0], [r0+%1+mmsize*1], m8, m9, m10, m11, mmsize*0, %2
%else
    QUANT_TWO [r0+%1+mmsize*0], [r0+%1+mmsize*1], [r1+mmsize*0], [r1+mmsize*1], [r2+mmsize*0], [r2+mmsize*1], mmsize*0, %2
%if mmsize==8
    QUANT_TWO [r0+%1+mmsize*2], [r0+%1+mmsize*3], [r1+mmsize*2], [r1+mmsize*3], [r2+mmsize*2], [r2+mmsize*3], mmsize*2, %2
%endif
%endif
%endmacro

%macro QUANT_4x4x4 0
cglobal quant_4x4x4, 3,3,7
%if UNIX64
    mova      m8, [r1+mmsize*0]
    mova      m9, [r1+mmsize*1]
    mova     m10, [r2+mmsize*0]
    mova     m11, [r2+mmsize*1]
%endif
    QUANT_4x4  0, 4
    QUANT_4x4 32, 5
    packssdw  m4, m5
    QUANT_4x4 64, 5
    QUANT_4x4 96, 6
    packssdw  m5, m6
    packssdw  m4, m5
%if mmsize == 16
    packssdw  m4, m4  ; AA BB CC DD
%endif
    packsswb  m4, m4  ; A B C D
    pxor      m3, m3
    pcmpeqb   m4, m3
    pmovmskb eax, m4
    not      eax
    and      eax, 0xf
    RET
%endmacro

INIT_MMX mmx2
QUANT_DC quant_2x2_dc, 1
%if ARCH_X86_64 == 0 ; not needed because sse2 is faster
QUANT_DC quant_4x4_dc, 4
INIT_MMX mmx
QUANT_AC quant_4x4, 4
QUANT_AC quant_8x8, 16
QUANT_4x4x4
%endif

INIT_XMM sse2
QUANT_DC quant_4x4_dc, 2, 8
QUANT_AC quant_4x4, 2
QUANT_AC quant_8x8, 8
QUANT_4x4x4

INIT_XMM ssse3
QUANT_DC quant_4x4_dc, 2, 8
QUANT_AC quant_4x4, 2
QUANT_AC quant_8x8, 8
QUANT_4x4x4

INIT_MMX ssse3
QUANT_DC quant_2x2_dc, 1

INIT_XMM sse4
;Not faster on Conroe, so only used in SSE4 versions
QUANT_DC quant_4x4_dc, 2, 8
QUANT_AC quant_4x4, 2
QUANT_AC quant_8x8, 8
%endif ; !HIGH_BIT_DEPTH



;=============================================================================
; dequant
;=============================================================================

%macro DEQUANT16_L 3
;;; %1      dct[y][x]
;;; %2,%3   dequant_mf[i_mf][y][x]
;;; m2      i_qbits
    mova     m0, %2
%if HIGH_BIT_DEPTH
    pmaddwd  m0, %1
    pslld    m0, m2
%else
    packssdw m0, %3
    pmullw   m0, %1
    psllw    m0, m2
%endif
    mova     %1, m0
%endmacro

%macro DEQUANT32_R 3
;;; %1      dct[y][x]
;;; %2,%3   dequant_mf[i_mf][y][x]
;;; m2      -i_qbits
;;; m3      f
;;; m4      0
    mova      m0, %1
%if HIGH_BIT_DEPTH
    pmadcswd  m0, m0, %2, m3
    psrad     m0, m2
%else
    punpckhwd m1, m0, m4
    punpcklwd m0, m4
    pmadcswd  m0, m0, %2, m3
    pmadcswd  m1, m1, %3, m3
    psrad     m0, m2
    psrad     m1, m2
    packssdw  m0, m1
%endif
    mova      %1, m0
%endmacro

%macro DEQUANT_LOOP 3
%if 8*(%2-2*%3)
    mov t0d, 8*(%2-2*%3)
%%loop:
    %1 [r0+(t0     )*SIZEOF_PIXEL], [r1+t0*2      ], [r1+t0*2+ 8*%3]
    %1 [r0+(t0+8*%3)*SIZEOF_PIXEL], [r1+t0*2+16*%3], [r1+t0*2+24*%3]
    sub t0d, 16*%3
    jge %%loop
    RET
%else
    %1 [r0+(8*%3)*SIZEOF_PIXEL], [r1+16*%3], [r1+24*%3]
    %1 [r0+(0   )*SIZEOF_PIXEL], [r1+0    ], [r1+ 8*%3]
    RET
%endif
%endmacro

%macro DEQUANT16_FLAT 2-5
    mova   m0, %1
    psllw  m0, m4
%assign i %0-2
%rep %0-1
%if i
    mova   m %+ i, [r0+%2]
    pmullw m %+ i, m0
%else
    pmullw m0, [r0+%2]
%endif
    mova   [r0+%2], m %+ i
    %assign i i-1
    %rotate 1
%endrep
%endmacro

%if WIN64
    DECLARE_REG_TMP 6,3,2
%elif ARCH_X86_64
    DECLARE_REG_TMP 4,3,2
%else
    DECLARE_REG_TMP 2,0,1
%endif

%macro DEQUANT_START 2
    movifnidn t2d, r2m
    imul t0d, t2d, 0x2b
    shr  t0d, 8     ; i_qbits = i_qp / 6
    lea  t1, [t0*3]
    sub  t2d, t1d
    sub  t2d, t1d   ; i_mf = i_qp % 6
    shl  t2d, %1
%if ARCH_X86_64
    add  r1, t2     ; dequant_mf[i_mf]
%else
    add  r1, r1mp   ; dequant_mf[i_mf]
    mov  r0, r0mp   ; dct
%endif
    sub  t0d, %2
    jl   .rshift32  ; negative qbits => rightshift
%endmacro

;-----------------------------------------------------------------------------
; void dequant_4x4( dctcoef dct[4][4], int dequant_mf[6][4][4], int i_qp )
;-----------------------------------------------------------------------------
%macro DEQUANT 3
cglobal dequant_%1x%1, 0,3,6
.skip_prologue:
    DEQUANT_START %2+2, %2

.lshift:
    movd m2, t0d
    DEQUANT_LOOP DEQUANT16_L, %1*%1/4, %3

.rshift32:
    neg   t0d
    movd  m2, t0d
    mova  m3, [pd_1]
    pxor  m4, m4
    pslld m3, m2
    psrld m3, 1
    DEQUANT_LOOP DEQUANT32_R, %1*%1/4, %3

%if HIGH_BIT_DEPTH == 0 && notcpuflag(avx)
cglobal dequant_%1x%1_flat16, 0,3
    movifnidn t2d, r2m
%if %1 == 8
    cmp  t2d, 12
    jl dequant_%1x%1 %+ SUFFIX %+ .skip_prologue
    sub  t2d, 12
%endif
    imul t0d, t2d, 0x2b
    shr  t0d, 8     ; i_qbits = i_qp / 6
    lea  t1, [t0*3]
    sub  t2d, t1d
    sub  t2d, t1d   ; i_mf = i_qp % 6
    shl  t2d, %2
%ifdef PIC
    lea  r1, [dequant%1_scale]
    add  r1, t2
%else
    lea  r1, [dequant%1_scale + t2]
%endif
    movifnidn r0, r0mp
    movd m4, t0d
%if %1 == 4
%if mmsize == 8
    DEQUANT16_FLAT [r1], 0, 16
    DEQUANT16_FLAT [r1+8], 8, 24
%else
    DEQUANT16_FLAT [r1], 0, 16
%endif
%elif mmsize == 8
    DEQUANT16_FLAT [r1], 0, 8, 64, 72
    DEQUANT16_FLAT [r1+16], 16, 24, 48, 56
    DEQUANT16_FLAT [r1+16], 80, 88, 112, 120
    DEQUANT16_FLAT [r1+32], 32, 40, 96, 104
%else
    DEQUANT16_FLAT [r1], 0, 64
    DEQUANT16_FLAT [r1+16], 16, 48, 80, 112
    DEQUANT16_FLAT [r1+32], 32, 96
%endif
    RET
%endif ; !HIGH_BIT_DEPTH && !AVX
%endmacro ; DEQUANT

%if HIGH_BIT_DEPTH
INIT_XMM sse2
DEQUANT 4, 4, 1
DEQUANT 8, 6, 1
INIT_XMM xop
DEQUANT 4, 4, 1
DEQUANT 8, 6, 1
%else
%if ARCH_X86_64 == 0
INIT_MMX mmx
DEQUANT 4, 4, 1
DEQUANT 8, 6, 1
%endif
INIT_XMM sse2
DEQUANT 4, 4, 2
DEQUANT 8, 6, 2
INIT_XMM avx
DEQUANT 4, 4, 2
DEQUANT 8, 6, 2
INIT_XMM xop
DEQUANT 4, 4, 2
DEQUANT 8, 6, 2
%endif

%macro DEQUANT_DC 2
cglobal dequant_4x4dc, 0,3,6
    DEQUANT_START 6, 6

.lshift:
    movd     m3, [r1]
    movd     m2, t0d
    pslld    m3, m2
    SPLAT%1  m3, m3, 0
%assign x 0
%rep SIZEOF_PIXEL*16/mmsize
    mova     m0, [r0+mmsize*0+x]
    mova     m1, [r0+mmsize*1+x]
    %2       m0, m3
    %2       m1, m3
    mova     [r0+mmsize*0+x], m0
    mova     [r0+mmsize*1+x], m1
%assign x x+mmsize*2
%endrep
    RET

.rshift32:
    neg   t0d
    movd  m3, t0d
    mova  m4, [p%1_1]
    mova  m5, m4
    pslld m4, m3
    psrld m4, 1
    movd  m2, [r1]
%assign x 0
%if HIGH_BIT_DEPTH
    pshufd m2, m2, 0
%rep SIZEOF_PIXEL*32/mmsize
    mova      m0, [r0+x]
    pmadcswd  m0, m0, m2, m4
    psrad     m0, m3
    mova      [r0+x], m0
%assign x x+mmsize
%endrep

%else ; !HIGH_BIT_DEPTH
    PSHUFLW   m2, m2, 0
    punpcklwd m2, m4
%rep SIZEOF_PIXEL*32/mmsize
    mova      m0, [r0+x]
    punpckhwd m1, m0, m5
    punpcklwd m0, m5
    pmaddwd   m0, m2
    pmaddwd   m1, m2
    psrad     m0, m3
    psrad     m1, m3
    packssdw  m0, m1
    mova      [r0+x], m0
%assign x x+mmsize
%endrep
%endif ; !HIGH_BIT_DEPTH
    RET
%endmacro

%if HIGH_BIT_DEPTH
INIT_XMM sse2
DEQUANT_DC d, pmaddwd
INIT_XMM xop
DEQUANT_DC d, pmaddwd
%else
%if ARCH_X86_64 == 0
INIT_MMX mmx2
DEQUANT_DC w, pmullw
%endif
INIT_XMM sse2
DEQUANT_DC w, pmullw
INIT_XMM avx
DEQUANT_DC w, pmullw
%endif

; t4 is eax for return value.
%if ARCH_X86_64
    DECLARE_REG_TMP 0,1,2,3,6,4  ; Identical for both Windows and *NIX
%else
    DECLARE_REG_TMP 4,1,2,3,0,5
%endif

;-----------------------------------------------------------------------------
; x264_optimize_chroma_2x2_dc( dctcoef dct[4], int dequant_mf )
;-----------------------------------------------------------------------------

%macro OPTIMIZE_CHROMA_2x2_DC 0
%assign %%regs 5
%if cpuflag(sse4)
    %assign %%regs %%regs-1
%endif
%if ARCH_X86_64 == 0
    %assign %%regs %%regs+1      ; t0-t4 are volatile on x86-64
%endif
cglobal optimize_chroma_2x2_dc, 0,%%regs,7
    movifnidn t0, r0mp
    movd      m2, r1m
    movq      m1, [t0]
%if cpuflag(sse4)
    pcmpeqb   m4, m4
    pslld     m4, 11
%else
    pxor      m4, m4
%endif
%if cpuflag(ssse3)
    mova      m3, [chroma_dc_dct_mask]
    mova      m5, [chroma_dc_dmf_mask]
%else
    mova      m3, [chroma_dc_dct_mask_mmx]
    mova      m5, [chroma_dc_dmf_mask_mmx]
%endif
    pshuflw   m2, m2, 0
    pshufd    m0, m1, q0101      ;  1  0  3  2  1  0  3  2
    punpcklqdq m2, m2
    punpcklqdq m1, m1            ;  3  2  1  0  3  2  1  0
    mova      m6, [pd_1024]      ; 32<<5, elements are shifted 5 bits to the left
    PSIGNW    m0, m3             ; -1 -0  3  2 -1 -0  3  2
    PSIGNW    m2, m5             ;  +  -  -  +  -  -  +  +
    paddw     m0, m1             ; -1+3 -0+2  1+3  0+2 -1+3 -0+2  1+3  0+2
    pmaddwd   m0, m2             ;  0-1-2+3  0-1+2-3  0+1-2-3  0+1+2+3  * dmf
    punpcklwd m1, m1
    psrad     m2, 16             ;  +  -  -  +
    mov      t1d, 3
    paddd     m0, m6
    xor      t4d, t4d
%if notcpuflag(ssse3)
    psrad     m1, 31             ; has to be 0 or -1 in order for PSIGND_MMX to work correctly
%endif
%if cpuflag(sse4)
    ptest     m0, m4
%else
    mova      m6, m0
    SWAP       0, 6
    psrad     m6, 11
    pcmpeqd   m6, m4
    pmovmskb t5d, m6
    cmp      t5d, 0xffff
%endif
    jz .ret                      ; if the DC coefficients already round to zero, terminate early
    mova      m3, m0
.outer_loop:
    movsx    t3d, word [t0+2*t1] ; dct[coeff]
    pshufd    m6, m1, q3333
    pshufd    m1, m1, q2100      ; move the next element to high dword
    PSIGND    m5, m2, m6
    test     t3d, t3d
    jz .loop_end
.outer_loop_0:
    mov      t2d, t3d
    sar      t3d, 31
    or       t3d, 1
.inner_loop:
    psubd     m3, m5             ; coeff -= sign
    pxor      m6, m0, m3
%if cpuflag(sse4)
    ptest     m6, m4
%else
    psrad     m6, 11
    pcmpeqd   m6, m4
    pmovmskb t5d, m6
    cmp      t5d, 0xffff
%endif
    jz .round_coeff
    paddd     m3, m5             ; coeff += sign
    mov      t4d, 1
.loop_end:
    dec      t1d
    jz .last_coeff
    pshufd    m2, m2, q1320      ;  -  +  -  +  /  -  -  +  +
    jg .outer_loop
.ret:
    REP_RET
.round_coeff:
    sub      t2d, t3d
    mov [t0+2*t1], t2w
    jnz .inner_loop
    jmp .loop_end
.last_coeff:
    movsx    t3d, word [t0]
    punpcklqdq m2, m2            ;  +  +  +  +
    PSIGND    m5, m2, m1
    test     t3d, t3d
    jnz .outer_loop_0
    RET
%endmacro

%if HIGH_BIT_DEPTH == 0
INIT_XMM sse2
OPTIMIZE_CHROMA_2x2_DC
INIT_XMM ssse3
OPTIMIZE_CHROMA_2x2_DC
INIT_XMM sse4
OPTIMIZE_CHROMA_2x2_DC
INIT_XMM avx
OPTIMIZE_CHROMA_2x2_DC
%endif ; !HIGH_BIT_DEPTH

%if HIGH_BIT_DEPTH
;-----------------------------------------------------------------------------
; void denoise_dct( int32_t *dct, uint32_t *sum, uint32_t *offset, int size )
;-----------------------------------------------------------------------------
%macro DENOISE_DCT 0
cglobal denoise_dct, 4,4,8
    pxor      m6, m6
    movsxdifnidn r3, r3d
.loop:
    mova      m2, [r0+r3*4-2*mmsize]
    mova      m3, [r0+r3*4-1*mmsize]
    ABSD      m0, m2
    ABSD      m1, m3
    mova      m4, m0
    mova      m5, m1
    psubd     m0, [r2+r3*4-2*mmsize]
    psubd     m1, [r2+r3*4-1*mmsize]
    pcmpgtd   m7, m0, m6
    pand      m0, m7
    pcmpgtd   m7, m1, m6
    pand      m1, m7
    PSIGND    m0, m2
    PSIGND    m1, m3
    mova      [r0+r3*4-2*mmsize], m0
    mova      [r0+r3*4-1*mmsize], m1
    paddd     m4, [r1+r3*4-2*mmsize]
    paddd     m5, [r1+r3*4-1*mmsize]
    mova      [r1+r3*4-2*mmsize], m4
    mova      [r1+r3*4-1*mmsize], m5
    sub       r3, mmsize/2
    jg .loop
    RET
%endmacro

%if ARCH_X86_64 == 0
INIT_MMX mmx
DENOISE_DCT
%endif
INIT_XMM sse2
DENOISE_DCT
INIT_XMM ssse3
DENOISE_DCT
INIT_XMM avx
DENOISE_DCT

%else ; !HIGH_BIT_DEPTH

;-----------------------------------------------------------------------------
; void denoise_dct( int16_t *dct, uint32_t *sum, uint16_t *offset, int size )
;-----------------------------------------------------------------------------
%macro DENOISE_DCT 0
cglobal denoise_dct, 4,4,7
    pxor      m6, m6
    movsxdifnidn r3, r3d
.loop:
    mova      m2, [r0+r3*2-2*mmsize]
    mova      m3, [r0+r3*2-1*mmsize]
    ABSW      m0, m2, sign
    ABSW      m1, m3, sign
    psubusw   m4, m0, [r2+r3*2-2*mmsize]
    psubusw   m5, m1, [r2+r3*2-1*mmsize]
    PSIGNW    m4, m2
    PSIGNW    m5, m3
    mova      [r0+r3*2-2*mmsize], m4
    mova      [r0+r3*2-1*mmsize], m5
    punpcklwd m2, m0, m6
    punpcklwd m3, m1, m6
    punpckhwd m0, m6
    punpckhwd m1, m6
    paddd     m2, [r1+r3*4-4*mmsize]
    paddd     m0, [r1+r3*4-3*mmsize]
    paddd     m3, [r1+r3*4-2*mmsize]
    paddd     m1, [r1+r3*4-1*mmsize]
    mova      [r1+r3*4-4*mmsize], m2
    mova      [r1+r3*4-3*mmsize], m0
    mova      [r1+r3*4-2*mmsize], m3
    mova      [r1+r3*4-1*mmsize], m1
    sub       r3, mmsize
    jg .loop
    RET
%endmacro

%if ARCH_X86_64 == 0
INIT_MMX mmx
DENOISE_DCT
%endif
INIT_XMM sse2
DENOISE_DCT
INIT_XMM ssse3
DENOISE_DCT
INIT_XMM avx
DENOISE_DCT

%endif ; !HIGH_BIT_DEPTH

;-----------------------------------------------------------------------------
; int decimate_score( dctcoef *dct )
;-----------------------------------------------------------------------------

%macro DECIMATE_MASK 5
%if mmsize==16
%if HIGH_BIT_DEPTH
    movdqa   xmm0, [%3+ 0]
    movdqa   xmm1, [%3+32]
    packssdw xmm0, [%3+16]
    packssdw xmm1, [%3+48]
    ABSW2    xmm0, xmm1, xmm0, xmm1, xmm3, xmm4
%else
    ABSW     xmm0, [%3+ 0], xmm3
    ABSW     xmm1, [%3+16], xmm4
%endif
    packsswb xmm0, xmm1
    pxor     xmm2, xmm2
    pcmpeqb  xmm2, xmm0
    pcmpgtb  xmm0, %4
    pmovmskb %1, xmm2
    pmovmskb %2, xmm0

%else ; mmsize==8
%if HIGH_BIT_DEPTH
    movq      mm0, [%3+ 0]
    movq      mm1, [%3+16]
    movq      mm2, [%3+32]
    movq      mm3, [%3+48]
    packssdw  mm0, [%3+ 8]
    packssdw  mm1, [%3+24]
    packssdw  mm2, [%3+40]
    packssdw  mm3, [%3+56]
%else
    movq      mm0, [%3+ 0]
    movq      mm1, [%3+ 8]
    movq      mm2, [%3+16]
    movq      mm3, [%3+24]
%endif
    ABSW2     mm0, mm1, mm0, mm1, mm6, mm7
    ABSW2     mm2, mm3, mm2, mm3, mm6, mm7
    packsswb  mm0, mm1
    packsswb  mm2, mm3
    pxor      mm4, mm4
    pxor      mm6, mm6
    pcmpeqb   mm4, mm0
    pcmpeqb   mm6, mm2
    pcmpgtb   mm0, %4
    pcmpgtb   mm2, %4
    pmovmskb   %5, mm4
    pmovmskb   %1, mm6
    shl        %1, 8
    or         %1, %5
    pmovmskb   %5, mm0
    pmovmskb   %2, mm2
    shl        %2, 8
    or         %2, %5
%endif
%endmacro

cextern decimate_table4
cextern decimate_table8

%macro DECIMATE4x4 1

;A LUT is faster than bsf on older AMD processors.
;This is not true for score64.
cglobal decimate_score%1, 1,3
%ifdef PIC
    lea r4, [decimate_table4]
    lea r5, [decimate_mask_table4]
    %define table r4
    %define mask_table r5
%else
    %define table decimate_table4
    %define mask_table decimate_mask_table4
%endif
    DECIMATE_MASK edx, eax, r0, [pb_1], ecx
    xor   edx, 0xffff
    je   .ret
    test  eax, eax
    jne  .ret9
%if %1==15
    shr   edx, 1
%endif
%if cpuflag(slowctz)
    movzx ecx, dl
    movzx eax, byte [mask_table + rcx]
    cmp   edx, ecx
    je   .ret
    bsr   ecx, ecx
    shr   edx, 1
    shr   edx, cl
    bsf   ecx, edx
    shr   edx, 1
    shr   edx, cl
    add    al, byte [table + rcx]
    add    al, byte [mask_table + rdx]
%else
.loop:
    tzcnt ecx, edx
    shr   edx, cl
    add    al, byte [table + rcx]
    shr   edx, 1
    jne  .loop
%endif
.ret:
    REP_RET
.ret9:
    mov   eax, 9
    RET

%endmacro

%if ARCH_X86_64 == 0
INIT_MMX mmx2
DECIMATE4x4 15
DECIMATE4x4 16
INIT_MMX mmx2, slowctz
DECIMATE4x4 15
DECIMATE4x4 16
%endif
INIT_XMM sse2
DECIMATE4x4 15
DECIMATE4x4 16
INIT_XMM sse2, slowctz
DECIMATE4x4 15
DECIMATE4x4 16
INIT_XMM ssse3
DECIMATE4x4 15
DECIMATE4x4 16
INIT_XMM ssse3, slowctz
DECIMATE4x4 15
DECIMATE4x4 16

%macro DECIMATE8x8 0

%if ARCH_X86_64
cglobal decimate_score64, 1,5
%ifdef PIC
    lea r4, [decimate_table8]
    %define table r4
%else
    %define table decimate_table8
%endif
    mova  m5, [pb_1]
    DECIMATE_MASK r1d, eax, r0+SIZEOF_DCTCOEF* 0, m5, null
    test  eax, eax
    jne  .ret9
    DECIMATE_MASK r2d, eax, r0+SIZEOF_DCTCOEF*16, m5, null
    shl   r2d, 16
    or    r1d, r2d
    DECIMATE_MASK r2d, r3d, r0+SIZEOF_DCTCOEF*32, m5, null
    shl   r2, 32
    or    eax, r3d
    or    r1, r2
    DECIMATE_MASK r2d, r3d, r0+SIZEOF_DCTCOEF*48, m5, null
    shl   r2, 48
    or    r1, r2
    xor   r1, -1
    je   .ret
    add   eax, r3d
    jne  .ret9
.loop:
    tzcnt rcx, r1
    shr   r1, cl
    add   al, byte [table + rcx]
    shr   r1, 1
    jne  .loop
.ret:
    REP_RET
.ret9:
    mov   eax, 9
    RET

%else ; ARCH
%if mmsize == 8
cglobal decimate_score64, 1,6
%else
cglobal decimate_score64, 1,5
%endif
    mova  m5, [pb_1]
    DECIMATE_MASK r3, r2, r0+SIZEOF_DCTCOEF* 0, m5, r5
    test  r2, r2
    jne  .ret9
    DECIMATE_MASK r4, r2, r0+SIZEOF_DCTCOEF*16, m5, r5
    shl   r4, 16
    or    r3, r4
    DECIMATE_MASK r4, r1, r0+SIZEOF_DCTCOEF*32, m5, r5
    or    r2, r1
    DECIMATE_MASK r1, r0, r0+SIZEOF_DCTCOEF*48, m5, r5
    shl   r1, 16
    or    r4, r1
    xor   r3, -1
    je   .tryret
    xor   r4, -1
.cont:
    add   r0, r2
    jne  .ret9      ;r0 is zero at this point, so we don't need to zero it
.loop:
    tzcnt ecx, r3
    test  r3, r3
    je   .largerun
    shrd  r3, r4, cl
    shr   r4, cl
    add   r0b, byte [decimate_table8 + ecx]
    shrd  r3, r4, 1
    shr   r4, 1
    cmp   r0, 6     ;score64's threshold is never higher than 6
    jge  .ret9      ;this early termination is only useful on 32-bit because it can be done in the latency after shrd
    test  r3, r3
    jne  .loop
    test  r4, r4
    jne  .loop
.ret:
    REP_RET
.tryret:
    xor   r4, -1
    jne  .cont
    RET
.ret9:
    mov   eax, 9
    RET
.largerun:
    mov   r3, r4
    xor   r4, r4
    tzcnt ecx, r3
    shr   r3, cl
    shr   r3, 1
    jne  .loop
    RET
%endif ; ARCH

%endmacro

%if ARCH_X86_64 == 0
INIT_MMX mmx2
DECIMATE8x8
%endif
INIT_XMM sse2
DECIMATE8x8
INIT_XMM ssse3
DECIMATE8x8

;-----------------------------------------------------------------------------
; int coeff_last( dctcoef *dct )
;-----------------------------------------------------------------------------

%macro BSR 3
%if cpuflag(lzcnt)
    lzcnt %1, %2
    xor %1, %3
%else
    bsr %1, %2
%endif
%endmacro

%macro LZCOUNT 3
%if cpuflag(lzcnt)
    lzcnt %1, %2
%else
    bsr %1, %2
    xor %1, %3
%endif
%endmacro

%if HIGH_BIT_DEPTH
%macro LAST_MASK 3-4
%if %1 == 4
    movq     mm0, [%3]
    packssdw mm0, [%3+8]
    packsswb mm0, mm0
    pcmpeqb  mm0, mm2
    pmovmskb  %2, mm0
%elif mmsize == 16
    movdqa   xmm0, [%3+ 0]
%if %1 == 8
    packssdw xmm0, [%3+16]
    packsswb xmm0, xmm0
%else
    movdqa   xmm1, [%3+32]
    packssdw xmm0, [%3+16]
    packssdw xmm1, [%3+48]
    packsswb xmm0, xmm1
%endif
    pcmpeqb  xmm0, xmm2
    pmovmskb   %2, xmm0
%elif %1 == 8
    movq     mm0, [%3+ 0]
    movq     mm1, [%3+16]
    packssdw mm0, [%3+ 8]
    packssdw mm1, [%3+24]
    packsswb mm0, mm1
    pcmpeqb  mm0, mm2
    pmovmskb  %2, mm0
%else
    movq     mm0, [%3+ 0]
    movq     mm1, [%3+16]
    packssdw mm0, [%3+ 8]
    packssdw mm1, [%3+24]
    movq     mm3, [%3+32]
    movq     mm4, [%3+48]
    packssdw mm3, [%3+40]
    packssdw mm4, [%3+56]
    packsswb mm0, mm1
    packsswb mm3, mm4
    pcmpeqb  mm0, mm2
    pcmpeqb  mm3, mm2
    pmovmskb  %2, mm0
    pmovmskb  %4, mm3
    shl       %4, 8
    or        %2, %4
%endif
%endmacro

%macro COEFF_LAST4 0
cglobal coeff_last4, 1,3
    pxor mm2, mm2
    LAST_MASK 4, r1d, r0
    xor  r1d, 0xff
    shr  r1d, 4
    BSR  eax, r1d, 0x1f
    RET
%endmacro

INIT_MMX mmx2
COEFF_LAST4
INIT_MMX mmx2, lzcnt
COEFF_LAST4

%macro COEFF_LAST8 0
cglobal coeff_last8, 1,3
    pxor m2, m2
    LAST_MASK 8, r1d, r0
%if mmsize == 16
    xor r1d, 0xffff
    shr r1d, 8
%else
    xor r1d, 0xff
%endif
    BSR eax, r1d, 0x1f
    RET
%endmacro

%if ARCH_X86_64 == 0
INIT_MMX mmx2
COEFF_LAST8
%endif
INIT_XMM sse2
COEFF_LAST8
INIT_XMM sse2, lzcnt
COEFF_LAST8

%else ; !HIGH_BIT_DEPTH
%macro LAST_MASK 3-4
%if %1 <= 8
    movq     mm0, [%3+ 0]
%if %1 == 4
    packsswb mm0, mm0
%else
    packsswb mm0, [%3+ 8]
%endif
    pcmpeqb  mm0, mm2
    pmovmskb  %2, mm0
%elif mmsize == 16
    movdqa   xmm0, [%3+ 0]
    packsswb xmm0, [%3+16]
    pcmpeqb  xmm0, xmm2
    pmovmskb   %2, xmm0
%else
    movq     mm0, [%3+ 0]
    movq     mm1, [%3+16]
    packsswb mm0, [%3+ 8]
    packsswb mm1, [%3+24]
    pcmpeqb  mm0, mm2
    pcmpeqb  mm1, mm2
    pmovmskb  %2, mm0
    pmovmskb  %4, mm1
    shl       %4, 8
    or        %2, %4
%endif
%endmacro

%macro COEFF_LAST48 0
%if ARCH_X86_64
cglobal coeff_last4, 1,1
    BSR  rax, [r0], 0x3f
    shr  eax, 4
    RET
%else
cglobal coeff_last4, 0,3
    mov   edx, r0mp
    mov   eax, [edx+4]
    xor   ecx, ecx
    test  eax, eax
    cmovz eax, [edx]
    setnz cl
    BSR   eax, eax, 0x1f
    shr   eax, 4
    lea   eax, [eax+ecx*2]
    RET
%endif

cglobal coeff_last8, 1,3
    pxor m2, m2
    LAST_MASK 8, r1d, r0, r2d
    xor r1d, 0xff
    BSR eax, r1d, 0x1f
    RET
%endmacro

INIT_MMX mmx2
COEFF_LAST48
INIT_MMX mmx2, lzcnt
COEFF_LAST48
%endif ; HIGH_BIT_DEPTH

%macro COEFF_LAST 0
cglobal coeff_last15, 1,3
    pxor m2, m2
    LAST_MASK 15, r1d, r0-SIZEOF_DCTCOEF, r2d
    xor r1d, 0xffff
    BSR eax, r1d, 0x1f
    dec eax
    RET

cglobal coeff_last16, 1,3
    pxor m2, m2
    LAST_MASK 16, r1d, r0, r2d
    xor r1d, 0xffff
    BSR eax, r1d, 0x1f
    RET

%if ARCH_X86_64 == 0
cglobal coeff_last64, 1, 5-mmsize/16
    pxor m2, m2
    LAST_MASK 16, r2d, r0+SIZEOF_DCTCOEF* 32, r4d
    LAST_MASK 16, r3d, r0+SIZEOF_DCTCOEF* 48, r4d
    shl r3d, 16
    or  r2d, r3d
    xor r2d, -1
    jne .secondhalf
    LAST_MASK 16, r1d, r0+SIZEOF_DCTCOEF* 0, r4d
    LAST_MASK 16, r3d, r0+SIZEOF_DCTCOEF*16, r4d
    shl r3d, 16
    or  r1d, r3d
    not r1d
    BSR eax, r1d, 0x1f
    RET
.secondhalf:
    BSR eax, r2d, 0x1f
    add eax, 32
    RET
%else
cglobal coeff_last64, 1,4
    pxor m2, m2
    LAST_MASK 16, r1d, r0+SIZEOF_DCTCOEF* 0
    LAST_MASK 16, r2d, r0+SIZEOF_DCTCOEF*16
    LAST_MASK 16, r3d, r0+SIZEOF_DCTCOEF*32
    LAST_MASK 16, r0d, r0+SIZEOF_DCTCOEF*48
    shl r2d, 16
    shl r0d, 16
    or  r1d, r2d
    or  r3d, r0d
    shl  r3, 32
    or   r1, r3
    not  r1
    BSR rax, r1, 0x3f
    RET
%endif
%endmacro

%if ARCH_X86_64 == 0
INIT_MMX mmx2
COEFF_LAST
%endif
INIT_XMM sse2
COEFF_LAST
INIT_XMM sse2, lzcnt
COEFF_LAST

;-----------------------------------------------------------------------------
; int coeff_level_run( dctcoef *dct, run_level_t *runlevel )
;-----------------------------------------------------------------------------

; t6 = eax for return, t3 = ecx for shift, t[01] = r[01] for x86_64 args
%if WIN64
    DECLARE_REG_TMP 3,1,2,0,4,5,6
%elif ARCH_X86_64
    DECLARE_REG_TMP 0,1,2,3,4,5,6
%else
    DECLARE_REG_TMP 6,3,2,1,4,5,0
%endif

%macro COEFF_LEVELRUN 1
cglobal coeff_level_run%1,0,7
    movifnidn t0, r0mp
    movifnidn t1, r1mp
    pxor    m2, m2
    LAST_MASK %1, t5d, t0-(%1&1)*SIZEOF_DCTCOEF, t4d
%if %1==15
    shr    t5d, 1
%elif %1==8
    and    t5d, 0xff
%elif %1==4
    and    t5d, 0xf
%endif
    xor    t5d, (1<<%1)-1
    mov [t1+4], t5d
    shl    t5d, 32-%1
    mov    t4d, %1-1
    LZCOUNT t3d, t5d, 0x1f
    xor    t6d, t6d
    add    t5d, t5d
    sub    t4d, t3d
    shl    t5d, t3b
    mov   [t1], t4d
.loop:
    LZCOUNT t3d, t5d, 0x1f
%if HIGH_BIT_DEPTH
    mov    t2d, [t0+t4*4]
%else
    mov    t2w, [t0+t4*2]
%endif
    inc    t3d
    shl    t5d, t3b
%if HIGH_BIT_DEPTH
    mov   [t1+t6*4+ 8], t2d
%else
    mov   [t1+t6*2+ 8], t2w
%endif
    inc    t6d
    sub    t4d, t3d
    jge .loop
    RET
%endmacro

INIT_MMX mmx2
%if ARCH_X86_64 == 0
COEFF_LEVELRUN 15
COEFF_LEVELRUN 16
%endif
COEFF_LEVELRUN 4
COEFF_LEVELRUN 8
INIT_XMM sse2
%if HIGH_BIT_DEPTH
COEFF_LEVELRUN 8
%endif
COEFF_LEVELRUN 15
COEFF_LEVELRUN 16
INIT_XMM sse2, lzcnt
%if HIGH_BIT_DEPTH
COEFF_LEVELRUN 8
%endif
COEFF_LEVELRUN 15
COEFF_LEVELRUN 16
INIT_MMX mmx2, lzcnt
COEFF_LEVELRUN 4
COEFF_LEVELRUN 8
