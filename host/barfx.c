/*
 * Smush the source, Luke!
 * Copyright (C) 2026 Gary V. Vaughan
 *
 * barfx FILE: unpack the barf at the end of FILE into the current
 * directory.
 *
 * It needs nothing but a C compiler, so that a first run can build it
 * and unpack the rest of what it needs.  It reads a plain `!<barf>`.
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
 * Each header is SIZE PATH, with SIZE in decimal.  The last line holds
 * the length of everything before it, in 15 digits.
 *
 * A barf is untrusted input, because the file might come from anyone.
 * Every length is checked against the bytes that remain, every path
 * must stay below the current directory (no absolute paths, `..` or
 * empty components).
 *
 * fseeko needs the POSIX feature macros on some systems, so
 * a build can put `-D_POSIX_C_SOURCE=200809L` in CPPFLAGS.
 */

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>


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


/* Read the digits at *S in BASE as a number into *N, and move *S past
 * them.  Return 0 if there are none, or the number is too big.  Unlike
 * strtoul, this accepts nothing before the digits, not even a sign.
 */
static int
digits(char **s, unsigned base, unsigned long *n)
{
    char *p = *s;
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


/* Whether the path P stays below the current directory. */
static int
path_ok(const char *p)
{
    size_t n;

    if (*p == '/')
        return 0;
    for (;;) {
        for (n = 0; p[n] != '\0' && p[n] != '/'; n++)
            ;
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


int
main(int argc, char **argv)
{
    static char line[8192], buf[65536];
    char tail[16], *e;
    FILE *in, *out;
    off_t end, length, left;
    unsigned long size;
    size_t i, n;
    int c;

    if (argc != 2)
        argfatal("usage: barfx FILE");
    if (!(in = fopen(argv[1], "rb")))
        sysfatal(argv[1]);

    /* The trailer: the length of the barf, 15 digits and a newline. */
    if (fseeko(in, -16, SEEK_END) || (end = ftello(in)) < 0 ||
        fread(tail, 1, 16, in) != 16 || tail[15] != '\n')
        fatal("no trailer");
    for (length = 0, i = 0; i < 15; i++) {
        if (tail[i] < '0' || tail[i] > '9')
            fatal("bad trailer");
        length = length * 10 + tail[i] - '0';
    }

    /* The barf starts LENGTH bytes before the trailer, with its magic
       line. */
    if (length < 8 || length > end || fseeko(in, end - length,
                                             SEEK_SET) ||
        !fgets(line, sizeof line, in) || strcmp(line, "!<barf>\n"))
        fatal("not a barf");

    /* LEFT is how much of the barf is still to read. */
    for (left = length - 8; left > 0;) {
        /* Read the header, SIZE PATH, one byte at a time, so that
           reading stops at its newline and goes no further. */
        for (n = 0; (c = getc(in)) != '\n'; )
            if (c == EOF || c == 0 || n == sizeof line - 1)
                fatal("bad header");
            else
                line[n++] = c;
        line[n] = 0;
        left -= (off_t) (n + 1);

        e = line;
        if (!digits(&e, 10, &size) || *e != ' ')
            fatal("bad header");

        /* The data and its trailing newline must fit in the rest of the
           barf. */
        if (!path_ok(e + 1) || left < 0 ||
            size >= (unsigned long) left)
            fatal("bad entry");
        e++;

        parents(e);
        if (!(out = fopen(e, "wb")))
            sysfatal(e);
        for (left -= (off_t) (size + 1); size; size -= n)
            if ((n = fread(buf, 1, size < sizeof buf ? size
                           : sizeof buf, in)) == 0 ||
                fwrite(buf, 1, n, out) != n)
                sysfatal(e);
        if (fclose(out))
            sysfatal(e);
        if (getc(in) != '\n')
            fatal("bad entry");
    }
    return 0;
}
