/*
 * Smush the source, Luke!
 * Copyright (C) 2026 Gary V. Vaughan
 *
 * barfx FILE: unpack the barf at the end of FILE into the current
 * directory.
 *
 * It needs nothing but a C compiler, so that a first run can build it
 * and unpack the rest of what it needs.  It reads a plain `!<barf>`,
 * or a compressed `!<barfz>`.
 *
 * A barf is a list of files.  It is found from the end of the file, so
 * it can follow a script or a program (see lib/smush/barf.lua):
 *
 *     !<barf>
 *     6 hello.txt
 *     Hello!
 *     17 bin/run
 *     #!/bin/sh
 *     echo hi
 *     000000000000056
 *
 * A header is SIZE PATH, with SIZE in decimal.
 * The last line gives the length of everything before it, in 15 digits.
 *
 * A compressed barf starts with !<barfz> instead.  Next come the
 * uncompressed length of the barf, then the barf itself (its magic line
 * and entries, without the last line) as one LZ4 block, and finally the
 * last line, with the length of all of it:
 *
 *     !<barfz>
 *     UUUUUUUUUUUUUUU
 *     the block
 *     LLLLLLLLLLLLLLL
 *
 * A barf is untrusted input, because the file might come from anyone.
 * Every length is checked against what is left, a path must stay below
 * the current directory (no absolute paths, `..` or empty components),
 * and decompression never reads or writes outside its buffers.
 *
 * fseeko needs the POSIX feature macros on some systems, so
 * a build can put `-D_POSIX_C_SOURCE=200809L` in CPPFLAGS.
 *
 * With BARFX_LIBRARY defined, including this file gives only what reads
 * a barf that is in memory, and not the program: digits, number,
 * barf_length and barf_entry.
 */

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>


/* Read the digits at *S in BASE as a number into *N, and move *S past
 * them.  Return 0 if there are none, or the number is too big.  Unlike
 * strtoul, this accepts nothing before the digits, not even a sign.
 */
static int
digits(const char **s, unsigned base, unsigned long *n)
{
    const char *p = *s;
    unsigned long v = 0;
    unsigned d;

    for (; *p >= '0' && (unsigned) (*p - '0') < base; p++) {
        d = (unsigned) (*p - '0');
        if (v > (ULONG_MAX - d) / base)
            return 0;
        v = v * base + d;
    }
    if (p == *s)
        return 0;
    *n = v;
    *s = p;
    return 1;
}


/* 0 if S starts with 15 digits, or else -1. */
static int
number(const unsigned char *s)
{
    int i;

    for (i = 0; i < 15; i++)
        if (s[i] < '0' || s[i] > '9')
            return -1;
    return 0;
}


/* Read the length from TAIL, the last 16 bytes of a barf: 15 digits and
 * a newline.  Return 0, or -1 if it is not that.
 */
static int
barf_length(const char *tail, unsigned long *length)
{
    const char *p = tail;

    if (number((const unsigned char *) tail) || tail[15] != '\n')
        return -1;
    return digits(&p, 10, length) ? 0 : -1;
}


/* Read the entry that starts at P, before STOP, the end of the barf: a
 * header SIZE PATH that ends with the first newline, then SIZE bytes of
 * data and a newline.  Point *NAME at the path, which is *NAMELEN bytes
 * and is not ended by a NUL, *DATA at the data, and set *SIZE.  Return
 * 0, or 1 if the header is bad, or 2 if the data is not all there.  It
 * reads the barf and never writes to it, so the barf can be constant.
 */
static int
barf_entry(const char *p, const char *stop, const char **name,
           unsigned long *namelen, const char **data, unsigned long *size)
{
    const char *nl, *e;

    if (!(nl = memchr(p, '\n', (size_t) (stop - p))) ||
        memchr(p, 0, (size_t) (nl - p)))
        return 1;
    *data = nl + 1;

    e = p;
    if (!digits(&e, 10, size) || *e != ' ')
        return 1;
    *name = e + 1;
    *namelen = (unsigned long) (nl - *name);

    /* The data and its trailing newline must fit in the rest of the
       barf. */
    if (*size >= (unsigned long) (stop - *data) ||
        (*data)[*size] != '\n')
        return 2;
    return 0;
}


#ifndef BARFX_LIBRARY


/* Report ERRMSG on stderr, and exit with status 1. */
static void
fatal(const char *errmsg)
{
    fprintf(stderr, "barfx: %s\n", errmsg);
    exit(1);
}


/* Like fatal, but add the error message of the last system call. */
static void
sysfatal(const char *errmsg)
{
    fprintf(stderr, "barfx: %s: %s\n", errmsg, strerror(errno));
    exit(1);
}


/* Report a bad command line on stderr, and exit with status 2. */
static void
argfatal(const char *errmsg)
{
    fprintf(stderr, "barfx: %s\n", errmsg);
    exit(2);
}


/* Whether the path P stays below the current directory. */
static int
path_ok(const char *p)
{
    size_t n;

    if (*p == '/')
        return 0;
    for (;;) {
        n = strcspn(p, "/");
        if (n == 0 || (n == 2 && p[0] == '.' && p[1] == '.'))
            return 0;
        if (!p[n])
            return 1;
        p += n + 1;
    }
}


/* Create any missing parent directories of the file P. */
static void
parents(char *p)
{
    char *s;

    for (s = strchr(p, '/'); s; s = strchr(s + 1, '/')) {
        *s = 0;
        mkdir(p, 0777);
        *s = '/';
    }
}


/* Decompress the N bytes of the block S into the M bytes of D, which it
 * must fill exactly.  A block is a run of sequences.  Each starts with
 * a token: its high four bits are the number of literal bytes, and its
 * low four bits the length of the copy, less four.  The literals
 * follow.  Every sequence but the last then has two bytes (low byte
 * first) of how far back the copy starts.  A count of 15 in the token
 * continues in the next bytes, each added to it, up to the first byte
 * that is not 255: right after the token for the literals, and after
 * the offset for the copy.  A copy can overlap the bytes it writes, so
 * it goes one byte at a time.  Nothing is read or written outside S and
 * D.  Returns 0 for a good block, or else -1.
 */
static int
unlz4(const unsigned char *s, size_t n, unsigned char *d, size_t m)
{
    const unsigned char *e = s + n;
    unsigned char *o = d, *oe = d + m;
    size_t l, k;
    unsigned t;

    while (s < e) {
        t = *s++;
        l = t >> 4;
        if (l == 15)
            do {
                if (s == e)
                    return -1;
                l += *s;
            } while (*s++ == 255);
        if ((size_t) (e - s) < l || (size_t) (oe - o) < l)
            return -1;
        memcpy(o, s, l);
        o += l;
        s += l;
        if (s == e)
            break;
        if (e - s < 2)
            return -1;
        k = s[0] | s[1] << 8;
        s += 2;
        l = t & 15;
        if (l == 15)
            do {
                if (s == e)
                    return -1;
                l += *s;
            } while (*s++ == 255);
        l += 4;
        if (k == 0 || k > (size_t) (o - d) || (size_t) (oe - o) < l)
            return -1;
        for (; l; l--, o++)
            *o = *(o - k);
    }
    return o == oe ? 0 : -1;
}


int
main(int argc, char **argv)
{
    unsigned char *body = NULL;
    char tail[16], *p, *stop, *name;
    const char *entry_name, *data;
    FILE *in, *out;
    off_t end;
    unsigned long size, namelen, length = 0, i;
    int bad;

    if (argc != 2)
        argfatal("usage: barfx FILE");
    if (!(in = fopen(argv[1], "rb")))
        sysfatal(argv[1]);

    /* The trailer: the length of the barf, 15 digits and a newline. */
    if (fseeko(in, -16, SEEK_END) || (end = ftello(in)) < 0 ||
        fread(tail, 1, 16, in) != 16 || barf_length(tail, &length))
        fatal("no trailer");

    /* The barf starts that far before the trailer.  Read all of it. */
    if (length < 8 || length > (unsigned long) end ||
        fseeko(in, end - (off_t) length, SEEK_SET) ||
        !(body = malloc(length)) || fread(body, 1, length,
                                          in) != length)
        fatal("not a barf");

    /* Decompress a compressed barf into a new buffer, whose size is
       the 15 digits after its magic line. */
    if (length >= 9 && !memcmp(body, "!<barfz>\n", 9)) {
        if (length < 25 || body[24] != '\n' || number(body + 9))
            fatal("bad compressed barf");
        for (size = 0, i = 9; i < 24; i++)
            size = size * 10 + body[i] - '0';
        p = (char *) body;
        if (size < 8 || !(body = malloc(size)) ||
            unlz4((unsigned char *) p + 25, length - 25, body, size))
            fatal("bad compressed barf");
        length = size;
    }
    if (memcmp(body, "!<barf>\n", 8))
        fatal("not a barf");

    /* Walk the entries, from after the magic line to the end. */
    for (p = (char *) body + 8, stop = (char *) body + length; p < stop;
         p += (data - p) + size + 1) {
        if ((bad = barf_entry(p, stop, &entry_name, &namelen, &data, &size)))
            fatal(bad == 1 ? "bad header" : "bad entry");

        /* The body is ours to write to, so end the path where the
           header ended. */
        name = p + (entry_name - p);
        name[namelen] = 0;
        if (!path_ok(name))
            fatal("bad entry");

        parents(name);
        if (!(out = fopen(name, "wb")) ||
            fwrite(data, 1, size, out) != size || fclose(out))
            sysfatal(name);
    }
    return 0;
}

#endif
