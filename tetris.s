//==========================================================================
//  TETRIS — macOS / Apple Silicon (arm64), čistý assembler bez knihoven
//
//  Program nevolá žádnou funkci z libc ani z jiné knihovny. Veškerá
//  komunikace s okolím jde přímo přes BSD syscally instrukcí `svc #0x80`
//  (číslo služby se předává v registru x16):
//      exit(1), read(3), write(4), ioctl(54), select(93), gettimeofday(116)
//
//  Terminál se přepíná do "raw" režimu přes ioctl TIOCGETA / TIOCSETA,
//  vykreslování je řešeno ANSI escape sekvencemi (256barevná paleta).
//==========================================================================

// ---------------------------------------------------------------- syscally
.equ SYS_EXIT,          1
.equ SYS_READ,          3
.equ SYS_WRITE,         4
.equ SYS_IOCTL,         54
.equ SYS_SELECT,        93
.equ SYS_GETTIMEOFDAY,  116

// ioctl kódy pro práci s termios (sizeof(struct termios) == 72)
.equ TIOCGETA,          0x40487413
.equ TIOCSETA,          0x80487414

// ---------------------------------------------------------- herní konstanty
.equ BW,                10          // šířka hrací plochy ve sloupcích
.equ BH,                20          // výška hrací plochy v řádcích
.equ CELLW,             13          // délka ANSI řetězce jedné buňky

// ------------------------------------------------- offsety v bloku stavu gs
.equ G_PIECE,           0           // index aktuálního kusu 0..6
.equ G_ROT,             4           // rotace 0..3
.equ G_X,               8           // pozice kusu (levý horní roh masky 4x4)
.equ G_Y,               12
.equ G_NEXT,            16          // index následujícího kusu
.equ G_SCORE,           20
.equ G_LINES,           24
.equ G_LEVEL,           28
.equ G_TICK,            32          // čítač tiků do dalšího pádu
.equ G_SPEED,           36          // počet tiků na jeden pád (tik = 20 ms)
.equ G_RNG,             40          // stav generátoru náhodných čísel
.equ G_PAUSED,          44
.equ G_QUIT,            48          // 0 = hraj, 1 = konec, 2 = restart
.equ G_DIRTY,           52          // 1 = je potřeba překreslit
.equ G_GHOST,           56          // y-pozice "ducha" (náhled dopadu)
.equ G_BAGIDX,          60          // pozice v pytli sedmi kusů
.equ G_OVER,            64          // 1 = konec hry

// ------------------------------------------------------------------- makra

// načtení adresy symbolu do registru (adrp + add)
.macro LEA reg, sym
    adrp    \reg, \sym@PAGE
    add     \reg, \reg, \sym@PAGEOFF
.endm

// načtení 32bitové konstanty do registru
.macro IMM32 reg, val
    movz    \reg, #((\val) & 0xffff)
    movk    \reg, #(((\val) >> 16) & 0xffff), lsl #16
.endm


.section __TEXT,__text
.global _start
.align 2

//==========================================================================
//  _start — vstupní bod programu
//==========================================================================
_start:
    bl      term_raw            // terminál do raw režimu
    bl      seed_rng            // inicializace generátoru náhody
    bl      screen_init         // skrytí kurzoru a smazání obrazovky

_restart:
    bl      game_init
    bl      game_loop           // x0: 1 = hrát znovu, 0 = skončit
    cmp     x0, #1
    b.eq    _restart

    bl      screen_done         // úklid obrazovky + výpis skóre
    bl      term_restore        // vrácení původního nastavení terminálu
    mov     x0, #0
    mov     x16, #SYS_EXIT
    svc     #0x80


//==========================================================================
//  term_raw — uloží původní termios a nastaví raw režim
//  (bez echa, bez řádkového bufferu, neblokující čtení: VMIN=0, VTIME=0)
//==========================================================================
term_raw:
    stp     x29, x30, [sp, #-16]!
    // načtení aktuálního nastavení terminálu
    mov     x0, #0
    IMM32   x1, TIOCGETA
    LEA     x2, orig_termios
    mov     x16, #SYS_IOCTL
    svc     #0x80

    // kopie struktury (72 bajtů) do pracovní verze
    LEA     x0, orig_termios
    LEA     x1, raw_termios
    mov     x2, #72
tr_copy:
    ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    subs    x2, x2, #1
    b.ne    tr_copy

    LEA     x1, raw_termios
    // c_iflag &= ~(BRKINT|ICRNL|INPCK|ISTRIP|IXON)
    ldr     x2, [x1, #0]
    mov     x3, #0x332
    bic     x2, x2, x3
    str     x2, [x1, #0]
    // c_oflag &= ~OPOST — výstup posíláme s explicitním \r\n
    ldr     x2, [x1, #8]
    bic     x2, x2, #1
    str     x2, [x1, #8]
    // c_lflag &= ~(ECHO|ICANON|IEXTEN|ISIG)
    ldr     x2, [x1, #24]
    mov     x3, #0x588
    bic     x2, x2, x3
    str     x2, [x1, #24]
    // c_cc[VMIN]=0 (offset 32+16), c_cc[VTIME]=0 → read() se nikdy nezablokuje
    strb    wzr, [x1, #48]
    strb    wzr, [x1, #49]

    mov     x0, #0
    IMM32   x1, TIOCSETA
    LEA     x2, raw_termios
    mov     x16, #SYS_IOCTL
    svc     #0x80
    ldp     x29, x30, [sp], #16
    ret


//==========================================================================
//  term_restore — obnoví původní nastavení terminálu
//==========================================================================
term_restore:
    mov     x0, #0
    IMM32   x1, TIOCSETA
    LEA     x2, orig_termios
    mov     x16, #SYS_IOCTL
    svc     #0x80
    ret


//==========================================================================
//  screen_init / screen_done — příprava a úklid obrazovky
//==========================================================================
screen_init:
    stp     x29, x30, [sp, #-16]!
    LEA     x0, s_enter
    bl      write_z
    ldp     x29, x30, [sp], #16
    ret

screen_done:
    stp     x29, x30, [sp, #-16]!
    // doplnění konečného skóre do textu
    LEA     x0, gs
    ldr     w0, [x0, #G_SCORE]
    LEA     x1, final_digits
    mov     w2, #6
    bl      put_num
    LEA     x0, s_leave
    bl      write_z
    LEA     x0, s_final
    bl      write_z
    ldp     x29, x30, [sp], #16
    ret


//==========================================================================
//  write_z — vypíše na stdout řetězec ukončený nulou (x0 = adresa)
//==========================================================================
write_z:
    mov     x1, x0
    mov     x2, #0
wz_len:
    ldrb    w3, [x1], #1
    cbz     w3, wz_out
    add     x2, x2, #1
    b       wz_len
wz_out:
    mov     x1, x0
    mov     x0, #1
    mov     x16, #SYS_WRITE
    svc     #0x80
    ret


//==========================================================================
//  seed_rng — osazení generátoru z gettimeofday a adresy zásobníku
//==========================================================================
seed_rng:
    LEA     x0, tv
    mov     x1, #0
    mov     x2, #0
    mov     x16, #SYS_GETTIMEOFDAY
    svc     #0x80
    mov     x5, x0                  // některé varianty vrací čas přímo v x0/x1
    mov     x6, x1
    LEA     x1, tv
    ldr     x2, [x1]                // tv_sec
    ldr     w3, [x1, #8]            // tv_usec
    eor     x2, x2, x3, lsl #20
    eor     x2, x2, x5
    eor     x2, x2, x6, lsl #7
    mov     x4, sp                  // trocha entropie z ASLR
    eor     x2, x2, x4, lsr #7
    orr     w2, w2, #1              // stav xorshiftu nesmí být nula
    LEA     x1, gs
    str     w2, [x1, #G_RNG]
    ret


//==========================================================================
//  rng_next — xorshift32, výsledek ve w0
//==========================================================================
rng_next:
    LEA     x1, gs
    ldr     w0, [x1, #G_RNG]
    eor     w0, w0, w0, lsl #13
    eor     w0, w0, w0, lsr #17
    eor     w0, w0, w0, lsl #5
    str     w0, [x1, #G_RNG]
    ret


//==========================================================================
//  bag_next — vrátí další kus z "pytle" (každá sedmice obsahuje všech
//  sedm tvarů v náhodném pořadí). Výsledek 0..6 ve w0.
//==========================================================================
bag_next:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]
    LEA     x19, gs
    ldr     w0, [x19, #G_BAGIDX]
    cmp     w0, #7
    b.lt    bag_take

    // naplnění pytle hodnotami 0..6
    LEA     x20, bag
    mov     w1, #0
bag_fill:
    strb    w1, [x20, w1, uxtw]
    add     w1, w1, #1
    cmp     w1, #7
    b.lt    bag_fill

    // zamíchání algoritmem Fisher–Yates odzadu
    mov     w21, #6
bag_shuf:
    bl      rng_next
    add     w1, w21, #1
    udiv    w2, w0, w1
    msub    w2, w2, w1, w0          // w2 = náhoda modulo (w21+1)
    ldrb    w3, [x20, w21, uxtw]
    ldrb    w4, [x20, w2, uxtw]
    strb    w4, [x20, w21, uxtw]
    strb    w3, [x20, w2, uxtw]
    subs    w21, w21, #1
    b.gt    bag_shuf
    str     wzr, [x19, #G_BAGIDX]

bag_take:
    ldr     w0, [x19, #G_BAGIDX]
    LEA     x1, bag
    ldrb    w2, [x1, w0, uxtw]
    add     w0, w0, #1
    str     w0, [x19, #G_BAGIDX]
    mov     w0, w2
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


//==========================================================================
//  mask_of — vrátí 16bitovou masku tvaru 4x4 (w0 = kus, w1 = rotace)
//==========================================================================
mask_of:
    LEA     x2, piece_masks
    lsl     w3, w0, #2
    add     w3, w3, w1
    ldrh    w0, [x2, w3, uxtw #1]
    ret


//==========================================================================
//  collide — test kolize kusu s okrajem plochy nebo s již ležícími kostkami
//  vstup:  w0 = kus, w1 = rotace, w2 = x, w3 = y (se znaménkem)
//  výstup: w0 = 1 při kolizi, jinak 0
//==========================================================================
collide:
    LEA     x4, piece_masks
    lsl     w5, w0, #2
    add     w5, w5, w1
    ldrh    w5, [x4, w5, uxtw #1]
    LEA     x10, board
    mov     w6, #0
col_loop:
    lsr     w7, w5, w6
    tbz     w7, #0, col_next
    lsr     w8, w6, #2              // řádek v masce
    and     w9, w6, #3              // sloupec v masce
    add     w8, w8, w3              // absolutní řádek
    add     w9, w9, w2              // absolutní sloupec
    // mimo levý/pravý okraj nebo pod dnem?
    cmp     w9, #0
    b.lt    col_hit
    cmp     w9, #BW
    b.ge    col_hit
    cmp     w8, #BH
    b.ge    col_hit
    // nad horním okrajem se kolize netestuje
    cmp     w8, #0
    b.lt    col_next
    mov     w11, #BW
    madd    w11, w8, w11, w9
    ldrb    w12, [x10, w11, uxtw]
    cbnz    w12, col_hit
col_next:
    add     w6, w6, #1
    cmp     w6, #16
    b.lt    col_loop
    mov     w0, #0
    ret
col_hit:
    mov     w0, #1
    ret


//==========================================================================
//  lock_piece — zapíše aktuální kus natrvalo do hrací plochy
//==========================================================================
lock_piece:
    LEA     x0, gs
    ldr     w1, [x0, #G_PIECE]
    ldr     w2, [x0, #G_ROT]
    ldr     w3, [x0, #G_X]
    ldr     w4, [x0, #G_Y]
    LEA     x5, piece_masks
    lsl     w6, w1, #2
    add     w6, w6, w2
    ldrh    w6, [x5, w6, uxtw #1]
    add     w7, w1, #1              // barva = index kusu + 1
    LEA     x8, board
    mov     w9, #0
lk_loop:
    lsr     w10, w6, w9
    tbz     w10, #0, lk_next
    lsr     w11, w9, #2
    and     w12, w9, #3
    add     w11, w11, w4
    add     w12, w12, w3
    cmp     w11, #0
    b.lt    lk_next
    cmp     w11, #BH
    b.ge    lk_next
    mov     w13, #BW
    madd    w13, w11, w13, w12
    strb    w7, [x8, w13, uxtw]
lk_next:
    add     w9, w9, #1
    cmp     w9, #16
    b.lt    lk_loop
    ret


//==========================================================================
//  clear_lines — smaže zaplněné řádky a posune obsah plochy dolů
//  výstup: w0 = počet smazaných řádků
//==========================================================================
clear_lines:
    LEA     x1, board
    mov     w2, #(BH - 1)           // zdrojový řádek
    mov     w3, #(BH - 1)           // cílový řádek
    mov     w4, #0                  // počet smazaných
cl_scan:
    tbnz    w2, #31, cl_fill        // došli jsme nad horní okraj
    mov     w9, #BW
    mul     w9, w2, w9
    add     x7, x1, w9, uxtw        // ukazatel na zdrojový řádek
    mov     w5, #0
    mov     w6, #1                  // předpoklad: řádek je plný
cl_col:
    ldrb    w9, [x7, w5, uxtw]
    cbnz    w9, cl_col_next
    mov     w6, #0
    b       cl_test
cl_col_next:
    add     w5, w5, #1
    cmp     w5, #BW
    b.lt    cl_col
cl_test:
    cbz     w6, cl_keep
    add     w4, w4, #1              // plný řádek se zahodí
    sub     w2, w2, #1
    b       cl_scan
cl_keep:
    cmp     w2, w3
    b.eq    cl_step
    mov     w9, #BW
    mul     w9, w3, w9
    add     x8, x1, w9, uxtw
    mov     w5, #0
cl_copy:
    ldrb    w9, [x7, w5, uxtw]
    strb    w9, [x8, w5, uxtw]
    add     w5, w5, #1
    cmp     w5, #BW
    b.lt    cl_copy
cl_step:
    sub     w2, w2, #1
    sub     w3, w3, #1
    b       cl_scan
cl_fill:
    // zbylé řádky nahoře se vyprázdní
    tbnz    w3, #31, cl_done
    mov     w9, #BW
    mul     w9, w3, w9
    add     x8, x1, w9, uxtw
    mov     w5, #0
cl_zero:
    strb    wzr, [x8, w5, uxtw]
    add     w5, w5, #1
    cmp     w5, #BW
    b.lt    cl_zero
    sub     w3, w3, #1
    b       cl_fill
cl_done:
    mov     w0, w4
    ret


//==========================================================================
//  add_score — připočte body a přepočítá úroveň a rychlost padání
//  vstup: w0 = počet smazaných řádků (1..4)
//==========================================================================
add_score:
    LEA     x1, score_tab
    ldr     w2, [x1, w0, uxtw #2]
    LEA     x3, gs
    ldr     w4, [x3, #G_LEVEL]
    mul     w2, w2, w4              // body se násobí úrovní
    ldr     w5, [x3, #G_SCORE]
    add     w5, w5, w2
    str     w5, [x3, #G_SCORE]
    ldr     w5, [x3, #G_LINES]
    add     w5, w5, w0
    str     w5, [x3, #G_LINES]
    // úroveň roste po každých deseti řádcích, maximum je 15
    mov     w6, #10
    udiv    w7, w5, w6
    add     w7, w7, #1
    cmp     w7, #15
    b.le    as_lvl
    mov     w7, #15
as_lvl:
    str     w7, [x3, #G_LEVEL]
    // rychlost: počet 20ms tiků na jeden pád, nejméně 2
    mov     w8, #26
    sub     w8, w8, w7, lsl #1
    cmp     w8, #2
    b.ge    as_spd
    mov     w8, #2
as_spd:
    str     w8, [x3, #G_SPEED]
    ret


//==========================================================================
//  spawn_piece — nasadí připravený kus na horní okraj plochy
//==========================================================================
spawn_piece:
    stp     x29, x30, [sp, #-32]!
    str     x19, [sp, #16]
    LEA     x19, gs
    ldr     w0, [x19, #G_NEXT]
    str     w0, [x19, #G_PIECE]
    bl      bag_next
    str     w0, [x19, #G_NEXT]
    str     wzr, [x19, #G_ROT]
    mov     w0, #3
    str     w0, [x19, #G_X]
    str     wzr, [x19, #G_Y]
    str     wzr, [x19, #G_TICK]
    // pokud se nový kus hned nevejde, hra končí
    ldr     w0, [x19, #G_PIECE]
    ldr     w1, [x19, #G_ROT]
    ldr     w2, [x19, #G_X]
    ldr     w3, [x19, #G_Y]
    bl      collide
    cbz     w0, sp_ok
    mov     w0, #1
    str     w0, [x19, #G_OVER]
sp_ok:
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


//==========================================================================
//  try_move — pokusí se posunout kus o (w0 = dx, w1 = dy)
//  výstup: w0 = 1 při úspěchu
//==========================================================================
try_move:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]
    LEA     x19, gs
    ldr     w2, [x19, #G_X]
    add     w20, w2, w0
    ldr     w2, [x19, #G_Y]
    add     w21, w2, w1
    ldr     w0, [x19, #G_PIECE]
    ldr     w1, [x19, #G_ROT]
    mov     w2, w20
    mov     w3, w21
    bl      collide
    cbnz    w0, tm_fail
    str     w20, [x19, #G_X]
    str     w21, [x19, #G_Y]
    mov     w0, #1
    b       tm_end
tm_fail:
    mov     w0, #0
tm_end:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


//==========================================================================
//  try_rotate — otočí kus (w0 = 1 doprava, 3 doleva) včetně odsunutí
//  od stěny ("wall kick") o -1, +1, -2 nebo +2 sloupce
//==========================================================================
try_rotate:
    stp     x29, x30, [sp, #-80]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    LEA     x19, gs
    ldr     w1, [x19, #G_ROT]
    add     w1, w1, w0
    and     w20, w1, #3             // cílová rotace
    LEA     x21, kicks
    mov     w22, #0
tr_loop:
    ldrsb   w4, [x21, w22, uxtw]
    ldr     w5, [x19, #G_X]
    add     w23, w5, w4             // kandidátní pozice x
    ldr     w0, [x19, #G_PIECE]
    mov     w1, w20
    mov     w2, w23
    ldr     w3, [x19, #G_Y]
    bl      collide
    cbnz    w0, tr_next
    str     w20, [x19, #G_ROT]
    str     w23, [x19, #G_X]
    mov     w0, #1
    b       tr_end
tr_next:
    add     w22, w22, #1
    cmp     w22, #5
    b.lt    tr_loop
    mov     w0, #0
tr_end:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #80
    ret


//==========================================================================
//  lock_and_next — zamkne kus, smaže řádky, boduje a nasadí další kus
//==========================================================================
lock_and_next:
    stp     x29, x30, [sp, #-32]!
    str     x19, [sp, #16]
    bl      lock_piece
    bl      clear_lines
    mov     w19, w0
    cbz     w19, lan_spawn
    mov     w0, w19
    bl      add_score
lan_spawn:
    bl      spawn_piece
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


//==========================================================================
//  step_down — posun o řádek dolů; když už to nejde, kus se zamkne
//==========================================================================
step_down:
    stp     x29, x30, [sp, #-16]!
    mov     w0, #0
    mov     w1, #1
    bl      try_move
    cbnz    w0, sd_end
    bl      lock_and_next
sd_end:
    ldp     x29, x30, [sp], #16
    ret


//==========================================================================
//  hard_drop — okamžitý pád až na dno (2 body za každý propadlý řádek)
//==========================================================================
hard_drop:
    stp     x29, x30, [sp, #-32]!
    str     x19, [sp, #16]
    mov     w19, #0
hd_loop:
    mov     w0, #0
    mov     w1, #1
    bl      try_move
    cbz     w0, hd_done
    add     w19, w19, #1
    b       hd_loop
hd_done:
    LEA     x0, gs
    ldr     w1, [x0, #G_SCORE]
    add     w1, w1, w19, lsl #1
    str     w1, [x0, #G_SCORE]
    bl      lock_and_next
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


//==========================================================================
//  put_num — zapíše číslo do bufferu zprava, doplněné nulami
//  vstup: w0 = hodnota, x1 = adresa první číslice, w2 = počet číslic
//==========================================================================
put_num:
    add     x1, x1, w2, uxtw        // ukazatel za poslední číslici
    mov     w3, #10
pn_loop:
    udiv    w4, w0, w3
    msub    w5, w4, w3, w0          // w5 = zbytek po dělení deseti
    add     w5, w5, #48
    strb    w5, [x1, #-1]!
    mov     w0, w4
    subs    w2, w2, #1
    b.ne    pn_loop
    ret


//==========================================================================
//  append / append_z — přidání dat do snímku obrazovky
//  x19 slouží jako průběžný ukazatel zápisu do bufferu `frame`
//==========================================================================
append:                             // x0 = zdroj, x1 = délka
    cbz     x1, ap_end
ap_loop:
    ldrb    w2, [x0], #1
    strb    w2, [x19], #1
    subs    x1, x1, #1
    b.ne    ap_loop
ap_end:
    ret

append_z:                           // x0 = řetězec ukončený nulou
az_loop:
    ldrb    w2, [x0], #1
    cbz     w2, az_end
    strb    w2, [x19], #1
    b       az_loop
az_end:
    ret


//==========================================================================
//  append_sidebar — připojí obsah postranního panelu pro daný řádek (w0)
//  Řádky 1..4 vykreslují náhled dalšího kusu, ostatní berou text z tabulky.
//==========================================================================
append_sidebar:
    stp     x29, x30, [sp, #-64]!
    stp     x20, x21, [sp, #16]
    stp     x22, x23, [sp, #32]
    mov     w20, w0
    sub     w0, w20, #1
    cmp     w0, #4                  // neznaménkový test rozsahu 1..4
    b.hs    sb_static
    mov     w20, w0                 // řádek náhledu 0..3

    LEA     x0, s_pad3
    bl      append_z
    LEA     x0, gs
    ldr     w21, [x0, #G_NEXT]
    mov     w0, w21
    mov     w1, #0
    bl      mask_of
    mov     w22, w0                 // maska náhledu
    mov     w23, #0
sb_pv:
    lsl     w0, w20, #2
    add     w0, w0, w23
    lsr     w0, w22, w0
    tbz     w0, #0, sb_pv_empty
    add     x0, x21, #1             // barva = index kusu + 1
    LEA     x1, cell_colors
    mov     x2, #CELLW
    madd    x0, x0, x2, x1
    mov     x1, #CELLW
    bl      append
    b       sb_pv_next
sb_pv_empty:
    LEA     x0, blank_cell
    mov     x1, #6
    bl      append
sb_pv_next:
    add     w23, w23, #1
    cmp     w23, #4
    b.lt    sb_pv
    LEA     x0, s_reset
    bl      append_z
    b       sb_end

sb_static:
    LEA     x0, sb_table
    ldr     x0, [x0, w20, uxtw #3]
    cbz     x0, sb_end
    bl      append_z
sb_end:
    ldp     x22, x23, [sp, #32]
    ldp     x20, x21, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret


//==========================================================================
//  render — sestaví celý snímek obrazovky do bufferu a vypíše ho jedním
//  voláním write(), aby obraz neblikal
//==========================================================================
render:
    stp     x29, x30, [sp, #-96]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]

    LEA     x22, gs

    // --- pozice "ducha": nejnižší místo, kam kus dopadne ---
    ldr     w23, [x22, #G_Y]
gh_loop:
    add     w23, w23, #1
    ldr     w0, [x22, #G_PIECE]
    ldr     w1, [x22, #G_ROT]
    ldr     w2, [x22, #G_X]
    mov     w3, w23
    bl      collide
    cbz     w0, gh_loop
    sub     w23, w23, #1
    str     w23, [x22, #G_GHOST]

    // --- aktualizace číselných údajů v postranním panelu ---
    ldr     w0, [x22, #G_SCORE]
    LEA     x1, score_digits
    mov     w2, #6
    bl      put_num
    ldr     w0, [x22, #G_LEVEL]
    LEA     x1, level_digits
    mov     w2, #2
    bl      put_num
    ldr     w0, [x22, #G_LINES]
    LEA     x1, lines_digits
    mov     w2, #3
    bl      put_num

    // --- údaje o aktuálním kusu do registrů, ať se nečtou pro každou buňku ---
    ldr     w25, [x22, #G_X]
    ldr     w26, [x22, #G_Y]
    ldr     w27, [x22, #G_GHOST]
    ldr     w0, [x22, #G_PIECE]
    add     w28, w0, #1             // barva aktuálního kusu
    ldr     w1, [x22, #G_ROT]
    bl      mask_of
    mov     w24, w0                 // maska aktuálního kusu

    LEA     x19, frame
    LEA     x0, s_home
    bl      append_z
    LEA     x0, s_title
    bl      append_z
    LEA     x0, s_top
    bl      append_z

    mov     w20, #0                 // index řádku
rw_row:
    LEA     x0, s_lb
    bl      append_z
    mov     w21, #0                 // index sloupce
rw_col:
    // 1) buňka patřící právě padajícímu kusu
    sub     w4, w20, w26
    sub     w5, w21, w25
    cmp     w4, #4
    b.hs    rc_notcur
    cmp     w5, #4
    b.hs    rc_notcur
    lsl     w6, w4, #2
    add     w6, w6, w5
    lsr     w7, w24, w6
    tbz     w7, #0, rc_notcur
    mov     w0, w28
    b       rc_emit
rc_notcur:
    // 2) již ležící kostka na hrací ploše
    LEA     x8, board
    mov     w9, #BW
    madd    w9, w20, w9, w21
    ldrb    w0, [x8, w9, uxtw]
    cbnz    w0, rc_emit
    // 3) náhled dopadu ("duch")
    sub     w4, w20, w27
    sub     w5, w21, w25
    cmp     w4, #4
    b.hs    rc_empty
    cmp     w5, #4
    b.hs    rc_empty
    lsl     w6, w4, #2
    add     w6, w6, w5
    lsr     w7, w24, w6
    tbz     w7, #0, rc_empty
    LEA     x0, ghost_cell
    mov     x1, #CELLW
    bl      append
    b       rc_done
rc_empty:
    mov     w0, #0
rc_emit:
    LEA     x1, cell_colors
    mov     x2, #CELLW
    madd    x0, x0, x2, x1
    mov     x1, #CELLW
    bl      append
rc_done:
    add     w21, w21, #1
    cmp     w21, #BW
    b.lt    rw_col

    LEA     x0, s_rb
    bl      append_z
    mov     w0, w20
    bl      append_sidebar
    LEA     x0, s_eol
    bl      append_z
    add     w20, w20, #1
    cmp     w20, #BH
    b.lt    rw_row

    LEA     x0, s_bot
    bl      append_z

    // stavový řádek pod plochou: pauza
    ldr     w0, [x22, #G_PAUSED]
    cbz     w0, rw_nopause
    LEA     x0, s_pause
    b       rw_pw
rw_nopause:
    LEA     x0, s_blankline
rw_pw:
    bl      append_z

    // stavový řádek pod plochou: konec hry
    ldr     w0, [x22, #G_OVER]
    cbz     w0, rw_noover
    LEA     x0, s_over
    b       rw_ow
rw_noover:
    LEA     x0, s_blankline
rw_ow:
    bl      append_z

    // jediný zápis celého snímku na stdout
    LEA     x1, frame
    sub     x2, x19, x1
    mov     x0, #1
    mov     x16, #SYS_WRITE
    svc     #0x80

    ldp     x27, x28, [sp, #80]
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #96
    ret


//==========================================================================
//  wait_input — čeká na klávesu nejvýše 20 ms (select na stdin)
//  výstup: x0 > 0 pokud je co číst
//==========================================================================
wait_input:
    LEA     x0, fdset
    str     xzr, [x0]
    str     xzr, [x0, #8]
    mov     w1, #1                  // bit 0 = deskriptor stdin
    str     w1, [x0]
    LEA     x1, tv
    str     xzr, [x1]               // tv_sec = 0
    mov     w2, #20000              // tv_usec = 20 ms
    str     w2, [x1, #8]
    mov     x0, #1
    LEA     x1, fdset
    mov     x2, #0
    mov     x3, #0
    LEA     x4, tv
    mov     x16, #SYS_SELECT
    svc     #0x80
    b.cs    wi_err                  // příznak carry signalizuje chybu
    ret
wi_err:
    mov     x0, #0
    ret


//==========================================================================
//  read_input — načte dostupné klávesy a provede odpovídající akce
//==========================================================================
read_input:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]
    mov     x0, #0
    LEA     x1, inbuf
    mov     x2, #32
    mov     x16, #SYS_READ
    svc     #0x80
    b.cs    ri_end
    cmp     x0, #1
    b.lt    ri_end
    mov     w19, w0                 // počet načtených bajtů
    mov     w20, #0                 // index zpracovávaného bajtu
    LEA     x0, gs
    mov     w1, #1
    str     w1, [x0, #G_DIRTY]      // po vstupu vždy překreslíme

ri_loop:
    cmp     w20, w19
    b.ge    ri_end
    LEA     x21, inbuf
    ldrb    w0, [x21, w20, uxtw]
    cmp     w0, #0x1b
    b.ne    ri_key

    // escape sekvence šipek: ESC [ A/B/C/D
    add     w1, w20, #2
    cmp     w1, w19
    b.ge    ri_skip1
    add     w1, w20, #1
    ldrb    w2, [x21, w1, uxtw]
    cmp     w2, #0x5b               // '['
    b.ne    ri_skip1
    add     w1, w20, #2
    ldrb    w0, [x21, w1, uxtw]
    add     w20, w20, #3
    cmp     w0, #0x41               // 'A' = nahoru
    b.eq    ri_rot
    cmp     w0, #0x42               // 'B' = dolů
    b.eq    ri_down
    cmp     w0, #0x43               // 'C' = doprava
    b.eq    ri_right
    cmp     w0, #0x44               // 'D' = doleva
    b.eq    ri_left
    b       ri_loop
ri_skip1:
    add     w20, w20, #1
    b       ri_loop

ri_key:
    add     w20, w20, #1
    cmp     w0, #3                  // Ctrl-C
    b.eq    ri_quit
    orr     w0, w0, #0x20           // převod na malé písmeno
    cmp     w0, #0x71               // 'q'
    b.eq    ri_quit
    cmp     w0, #0x70               // 'p'
    b.eq    ri_pause
    cmp     w0, #0x72               // 'r'
    b.eq    ri_restart
    cmp     w0, #0x61               // 'a'
    b.eq    ri_left
    cmp     w0, #0x64               // 'd'
    b.eq    ri_right
    cmp     w0, #0x73               // 's'
    b.eq    ri_down
    cmp     w0, #0x77               // 'w'
    b.eq    ri_rot
    cmp     w0, #0x78               // 'x'
    b.eq    ri_rot
    cmp     w0, #0x7a               // 'z'
    b.eq    ri_rotccw
    cmp     w0, #0x20               // mezerník
    b.eq    ri_drop
    b       ri_loop

// --- jednotlivé akce (pohyb je při pauze ignorován) ---
ri_left:
    LEA     x1, gs
    ldr     w1, [x1, #G_PAUSED]
    cbnz    w1, ri_loop
    mov     w0, #-1
    mov     w1, #0
    bl      try_move
    b       ri_loop
ri_right:
    LEA     x1, gs
    ldr     w1, [x1, #G_PAUSED]
    cbnz    w1, ri_loop
    mov     w0, #1
    mov     w1, #0
    bl      try_move
    b       ri_loop
ri_down:
    LEA     x1, gs
    ldr     w1, [x1, #G_PAUSED]
    cbnz    w1, ri_loop
    bl      step_down
    LEA     x1, gs
    str     wzr, [x1, #G_TICK]      // ruční posun resetuje čítač pádu
    b       ri_loop
ri_rot:
    LEA     x1, gs
    ldr     w1, [x1, #G_PAUSED]
    cbnz    w1, ri_loop
    mov     w0, #1
    bl      try_rotate
    b       ri_loop
ri_rotccw:
    LEA     x1, gs
    ldr     w1, [x1, #G_PAUSED]
    cbnz    w1, ri_loop
    mov     w0, #3
    bl      try_rotate
    b       ri_loop
ri_drop:
    LEA     x1, gs
    ldr     w1, [x1, #G_PAUSED]
    cbnz    w1, ri_loop
    bl      hard_drop
    b       ri_loop
ri_pause:
    LEA     x1, gs
    ldr     w2, [x1, #G_PAUSED]
    eor     w2, w2, #1
    str     w2, [x1, #G_PAUSED]
    b       ri_loop
ri_quit:
    LEA     x1, gs
    mov     w2, #1
    str     w2, [x1, #G_QUIT]
    b       ri_end
ri_restart:
    LEA     x1, gs
    mov     w2, #2
    str     w2, [x1, #G_QUIT]
    b       ri_end
ri_end:
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


//==========================================================================
//  game_init — nová hra: prázdná plocha, vynulované skóre, první kus
//==========================================================================
game_init:
    stp     x29, x30, [sp, #-32]!
    str     x19, [sp, #16]
    LEA     x19, gs
    LEA     x0, board
    mov     x1, #(BW * BH)
gi_clear:
    strb    wzr, [x0], #1
    subs    x1, x1, #1
    b.ne    gi_clear
    str     wzr, [x19, #G_SCORE]
    str     wzr, [x19, #G_LINES]
    mov     w0, #1
    str     w0, [x19, #G_LEVEL]
    str     wzr, [x19, #G_TICK]
    mov     w0, #24                 // úroveň 1 → pád po 480 ms
    str     w0, [x19, #G_SPEED]
    str     wzr, [x19, #G_PAUSED]
    str     wzr, [x19, #G_QUIT]
    str     wzr, [x19, #G_OVER]
    mov     w0, #7                  // vynutí naplnění pytle kusů
    str     w0, [x19, #G_BAGIDX]
    bl      bag_next
    str     w0, [x19, #G_NEXT]
    bl      spawn_piece
    mov     w0, #1
    str     w0, [x19, #G_DIRTY]
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


//==========================================================================
//  game_loop — hlavní smyčka hry
//  výstup: x0 = 1 pokud si hráč přeje novou hru, 0 při ukončení
//==========================================================================
game_loop:
    stp     x29, x30, [sp, #-32]!
    str     x19, [sp, #16]
    LEA     x19, gs
gl_loop:
    // překreslujeme jen tehdy, když se něco změnilo
    ldr     w0, [x19, #G_DIRTY]
    cbz     w0, gl_nodraw
    str     wzr, [x19, #G_DIRTY]
    bl      render
gl_nodraw:
    bl      wait_input
    cmp     x0, #0
    b.le    gl_tick
    bl      read_input
gl_tick:
    ldr     w0, [x19, #G_QUIT]
    cbnz    w0, gl_quit
    ldr     w0, [x19, #G_OVER]
    cbnz    w0, gl_over
    ldr     w0, [x19, #G_PAUSED]
    cbnz    w0, gl_loop
    // odpočet do dalšího samovolného pádu
    ldr     w0, [x19, #G_TICK]
    add     w0, w0, #1
    str     w0, [x19, #G_TICK]
    ldr     w1, [x19, #G_SPEED]
    cmp     w0, w1
    b.lt    gl_loop
    str     wzr, [x19, #G_TICK]
    bl      step_down
    mov     w0, #1
    str     w0, [x19, #G_DIRTY]
    b       gl_loop

gl_over:
    // vykreslení konečného stavu a čekání na volbu hráče
    bl      render
gl_over_wait:
    bl      wait_input
    cmp     x0, #0
    b.le    gl_over_wait
    mov     x0, #0
    LEA     x1, inbuf
    mov     x2, #32
    mov     x16, #SYS_READ
    svc     #0x80
    b.cs    gl_over_wait
    cmp     x0, #1
    b.lt    gl_over_wait
    LEA     x2, inbuf
    ldrb    w0, [x2]
    orr     w0, w0, #0x20
    cmp     w0, #0x72               // 'r' = nová hra
    b.eq    gl_again
    mov     x0, #0
    b       gl_ret

gl_quit:
    ldr     w0, [x19, #G_QUIT]
    cmp     w0, #2                  // 2 = restart vyžádaný klávesou R
    b.eq    gl_again
    mov     x0, #0
    b       gl_ret
gl_again:
    mov     x0, #1
gl_ret:
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


//==========================================================================
//  Data
//==========================================================================
.section __DATA,__data
.align 3

// Masky tetromin: 7 tvarů × 4 rotace, bit (řádek*4 + sloupec) mřížky 4×4.
// Pořadí tvarů odpovídá barvám v tabulce cell_colors: I, O, T, S, Z, J, L.
piece_masks:
    .short 0x00F0, 0x4444, 0x0F00, 0x2222       // I
    .short 0x0066, 0x0066, 0x0066, 0x0066       // O
    .short 0x0072, 0x0262, 0x0270, 0x0232       // T
    .short 0x0036, 0x0462, 0x0360, 0x0231       // S
    .short 0x0063, 0x0264, 0x0630, 0x0132       // Z
    .short 0x0071, 0x0226, 0x0470, 0x0322       // J
    .short 0x0074, 0x0622, 0x0170, 0x0223       // L

// Posuny zkoušené při rotaci u stěny nebo jiného kusu.
kicks:
    .byte 0, -1, 1, -2, 2

.align 2
// Body za 0 až 4 najednou smazané řádky (dále se násobí úrovní).
score_tab:
    .word 0, 100, 300, 500, 800

// ANSI řetězce jednotlivých buněk — všechny mají přesně CELLW bajtů.
cell_colors:
    .ascii "\033[48;5;235m  "       // 0 = prázdné pole
    .ascii "\033[48;5;051m  "       // 1 = I (azurová)
    .ascii "\033[48;5;226m  "       // 2 = O (žlutá)
    .ascii "\033[48;5;201m  "       // 3 = T (purpurová)
    .ascii "\033[48;5;046m  "       // 4 = S (zelená)
    .ascii "\033[48;5;196m  "       // 5 = Z (červená)
    .ascii "\033[48;5;021m  "       // 6 = J (modrá)
    .ascii "\033[48;5;208m  "       // 7 = L (oranžová)
ghost_cell:
    .ascii "\033[48;5;238m  "       // náhled místa dopadu
blank_cell:
    .ascii "\033[0m  "              // prázdné pole v náhledu (6 bajtů)

// Statické části obrazovky
s_enter:     .asciz "\033[?25l\033[2J\033[H"
s_leave:     .asciz "\033[0m\033[?25h\r\n"
s_home:      .asciz "\033[H"
s_title:     .asciz "\033[1;36m  T E T R I S\033[0m   \033[2marm64 · macOS · bez knihoven\033[0m\033[K\r\n"
s_top:       .asciz "\033[38;5;244m  ╔════════════════════╗\033[0m\033[K\r\n"
s_bot:       .asciz "\033[38;5;244m  ╚════════════════════╝\033[0m\033[K\r\n"
s_lb:        .asciz "\033[38;5;244m  ║\033[0m"
s_rb:        .asciz "\033[0m\033[38;5;244m║\033[0m"
s_eol:       .asciz "\033[K\r\n"
s_blankline: .asciz "\033[K\r\n"
s_pause:     .asciz "  \033[1;33m*** PAUZA — klávesou P pokračuj ***\033[0m\033[K\r\n"
s_over:      .asciz "  \033[1;31m*** KONEC HRY ***\033[0m  \033[2mR = nová hra, Q = konec\033[0m\033[K\r\n"
s_pad3:      .asciz "   "
s_reset:     .asciz "\033[0m"

// Postranní panel — texty jsou zapisovatelné, číslice se přepisují za běhu.
sb_next:     .asciz "   \033[1mDALŠÍ\033[0m"
sb_empty:    .asciz ""
sb_score:     .ascii "   SKÓRE:  "
score_digits: .ascii "000000"
              .byte 0
sb_level:     .ascii "   ÚROVEŇ: "
level_digits: .ascii "00"
              .byte 0
sb_lines:     .ascii "   ŘÁDKY:  "
lines_digits: .ascii "000"
              .byte 0
sb_h1:       .asciz "   \033[36m← →\033[0m    posun"
sb_h2:       .asciz "   \033[36m↑ / X\033[0m  otočit"
sb_h3:       .asciz "   \033[36mZ\033[0m      otočit zpět"
sb_h4:       .asciz "   \033[36m↓\033[0m      o řádek níž"
sb_h5:       .asciz "   \033[36mmezera\033[0m dopad"
sb_h6:       .asciz "   \033[36mP\033[0m      pauza"
sb_h7:       .asciz "   \033[36mR\033[0m      nová hra"
sb_h8:       .asciz "   \033[36mQ\033[0m      konec"

s_final:      .ascii "  Konečné skóre: "
final_digits: .ascii "000000"
              .byte 13, 10, 0

.align 3
// Přiřazení textu postranního panelu k řádkům hrací plochy.
// Nula znamená, že se řádek vykresluje zvlášť (náhled dalšího kusu).
sb_table:
    .quad sb_next       // 0
    .quad 0             // 1
    .quad 0             // 2
    .quad 0             // 3
    .quad 0             // 4
    .quad sb_empty      // 5
    .quad sb_score      // 6
    .quad sb_level      // 7
    .quad sb_lines      // 8
    .quad sb_empty      // 9
    .quad sb_h1         // 10
    .quad sb_h2         // 11
    .quad sb_h3         // 12
    .quad sb_h4         // 13
    .quad sb_h5         // 14
    .quad sb_h6         // 15
    .quad sb_h7         // 16
    .quad sb_h8         // 17
    .quad sb_empty      // 18
    .quad sb_empty      // 19


//==========================================================================
//  Neinicializovaná data
//==========================================================================
.zerofill __DATA,__bss,gs,128,3             // blok herního stavu
.zerofill __DATA,__bss,board,200,3          // hrací plocha 10 × 20 bajtů
.zerofill __DATA,__bss,bag,8,3              // pytel sedmi kusů
.zerofill __DATA,__bss,orig_termios,72,3    // původní nastavení terminálu
.zerofill __DATA,__bss,raw_termios,72,3     // nastavení pro raw režim
.zerofill __DATA,__bss,fdset,128,3          // fd_set pro select()
.zerofill __DATA,__bss,tv,16,3              // struct timeval
.zerofill __DATA,__bss,inbuf,64,3           // buffer načtených kláves
.zerofill __DATA,__bss,frame,16384,3        // sestavený snímek obrazovky
