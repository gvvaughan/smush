/*
 * Smush the source, Luke!
 * Copyright (C) 2026 Gary V. Vaughan
 *
 * crush FILE
 *
 * Runs a build script on a machine that has a C compiler and little
 * else.  The first run of a standalone program compiles it, and runs
 * the program's build script with it.
 *
 * Syntax:
 *
 *     script    = command { ( NEWLINE | ';' ) command }
 *     command   = { assign } [ word { word } ] { redirect }
 *     assign    = NAME '=' [ word | '[' { word } ']' ]
 *     redirect  = [ DIGIT ] ( '>' | '>>' ) word
 *     word      = part { part }
 *     part      = text | '$' NAME | '...' | "...$NAME..."
 *
 * A `#` starts a comment, and a backslash at the end of a line
 * continues it.  An assignment on its own sets a variable for the rest
 * of the script, and one before a command sets it for that command.
 *
 * Builtins:
 *
 *     cd [DIR]          change directory (to $HOME without DIR)
 *     exit [N]          end the script with status N, or with the
 *                       status of the last command
 *     embed NAME FILE   write C that defines the bytes of FILE as
 *                       `const unsigned char NAME_data[]`, and their
 *                       number as `const unsigned long NAME_size`
 *     sha256 FILE...    write the SHA-256 sum of each FILE, as
 *                       `HASH  FILE`, the way sha256sum does
 *     run COMMAND...    write `% COMMAND...` on stderr, with the words
 *                       expanded, and then run COMMAND
 *
 * Any other command is a program found in $PATH.  A command that exits
 * with a status other than 0 ends the script with that status.  Crush
 * itself exits with 3 when the script is wrong, with 2 when the command
 * line is, and with 1 when it fails on its own, for example to read the
 * script.
 *
 * What to know when writing a script:
 *
 *  - A value is a list of strings: `a=x`, `a=[x y z]`, and `a=` for
 *    an empty list.  `$a` is the list, and `"$a"` is one string with
 *    the items joined by spaces.
 *  - The parts of a word multiply, as in rc.  With `d=[a b]`, `-I$d` is
 *    `-Ia -Ib`.  A list of one joins to every item of another, lists of
 *    the same length join in pairs, and an empty list makes the whole
 *    word disappear.  Other lengths are an error.
 *  - A word is never split again, and never expanded as a pattern, so
 *    `*` is a plain `*`: name every file.
 *  - A name that the script has not set comes from the environment.
 *    Its value is split at blanks into a list, so `CC='ccache cc'` is
 *    two words and CFLAGS is a word for each flag.  An unset name is an
 *    empty list.  In double quotes the value is not split but kept as
 *    it is, so write `"$OUT/host"` for a path that may have a blank.
 *  - A variable that the script sets is not exported: write
 *    `name=value command` to give one command a variable.
 *  - Inside `'...'` nothing is special.  Inside `"..."` only `$name`
 *    is, and a backslash escapes `"`, `$`, `\` and a newline.  Outside
 *    quotes a backslash makes the next character literal.
 *  - There are no pipes, `&`, `<`, `( )`, backticks, `$(...)`,
 *    `${...}`, `$$`, `$?`, `$#name`, `{ }` as words, or keywords such
 *    as `if`, `for` and `while`.  Crush rejects a script that has one,
 *    with its line and column, before any of it runs.  Use
 *    `sh -c '...'` for anything else.
 *
 * It is C99 with POSIX.1-2001 (`-D_XOPEN_SOURCE=700`), and frees
 * nothing, since it runs one script and exits.
 */

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* A list of strings. */
typedef struct {
    char **item;
    size_t n;
} list;

/* One part of a word: literal text, or the name of a variable.  A
   quoted variable expands to one string: the items of a list that the
   script set, joined by spaces, or the value from the environment. */
typedef struct {
    char *text;
    int variable, quoted;
} part;

typedef struct {
    part *part;
    size_t n;
    int bare;  /* has no quotes and no variables */
} word;

typedef struct {
    char *name;
    word *value;
    size_t n;
} assign;

typedef struct {
    int fd, append;
    word target;
} redirect;

typedef struct {
    assign *assign;
    word *word;
    redirect *redirect;
    size_t nassign, nword, nredirect;
    const char *at;  /* where it starts, for error messages */
} command;

typedef struct {
    char *name;
    list value;
} variable;

static const char *script_name = "crush", *text;
static variable *vars;
static size_t nvars;
static int status;


/* Report ERRMSG on stderr, and exit with status 1. */
static void
fatal(const char *errmsg)
{
    fprintf(stderr, "crush: %s\n", errmsg);
    exit(1);
}


/* Like fatal, but add the error message of the last system call. */
static void
sysfatal(const char *errmsg)
{
    fprintf(stderr, "crush: %s: %s\n", errmsg, strerror(errno));
    exit(1);
}


/* Report a bad command line on stderr, and exit with status 2. */
static void
argfatal(const char *errmsg)
{
    fprintf(stderr, "crush: %s\n", errmsg);
    exit(2);
}


static void *
xrealloc(void *p, size_t n)
{
    if (!(p = realloc(p, n ? n : 1)))
        fatal("out of memory");
    return p;
}


/* Append a zeroed element of SIZE bytes to the array *P of *N
   elements, and return a pointer to it. */
static void *
grow(void *p, size_t *n, size_t size)
{
    char *e;

    *(void **) p = xrealloc(*(void **) p, (*n + 1) * size);
    e = (char *) *(void **) p + (*n)++ * size;
    memset(e, 0, size);
    return e;
}


/* A copy of the N bytes at S, with a \0 after them. */
static char *
xmemdupz(const char *s, size_t n)
{
    char *p = xrealloc(NULL, n + 1);
    memcpy(p, s, n);
    p[n] = '\0';
    return p;
}


/* Report ERRMSG, a problem with the script at AT, on stderr, and return
   the exit status that a bad script earns. */
static int
parseerror(const char *at, const char *errmsg)
{
    int line = 1, column = 1;
    const char *p;

    for (p = text; p < at; p++)
        if (*p == '\n')
            line++, column = 1;
        else
            column++;
    fprintf(stderr, "%s: %d:%d: %s\n", script_name, line, column,
            errmsg);
    return 3;
}


/* Parsing. */

static const char *keywords[] = {"if", "else", "for", "in", "while",
    "switch", "case", "fn", NULL};


static int
blank(int c)
{
    return c == ' ' || c == '\t';
}


static int
name_char(int c)
{
    return isalnum(c) || c == '_';
}


/* Add a part to the word W. */
static void
add_part(word *w, char *textz, int variable, int quoted)
{
    part *p = grow(&w->part, &w->n, sizeof *p);

    p->text = textz;
    p->variable = variable;
    p->quoted = quoted;
    if (variable || quoted)
        w->bare = 0;
}


/* Add the variable named after the `$` at TZ to the word W as a part,
   and return where the name ends. */
static const char *
add_variable(word *w, const char *tz, int quoted)
{
    const char *start = ++tz;

    while (name_char((unsigned char) *tz))
        tz++;
    if (tz == start)
        exit(parseerror(start - 1,
                        "a $ is followed by a name, as in $name: "
                        "nothing else is in crush"));
    if (*tz == '[')
        exit(parseerror(tz, "no subscripts: they are not in crush"));
    add_part(w, xmemdupz(start, (size_t) (tz - start)), 1, quoted);
    return tz;
}


/* Parse the word that starts at TZ into W, and return where it ends:
   at a blank, a newline, a `;`, a `>`, or a `]` when INLIST. */
static const char *
parse_word(word *w, const char *tz, int inlist)
{
    char *s = NULL;
    const char *open;
    size_t n = 0;

    w->bare = 1;
#define PUT(c) (s = xrealloc(s, n + 1), s[n++] = (char) (c))
#define FLUSH() \
    do { if (n) add_part(w, xmemdupz(s, n), 0, 0); n = 0; } while (0)
    for (; *tz && !blank((unsigned char) *tz) && !strchr("\n;>", *tz)
         && !(inlist && *tz == ']'); ) {
        if (*tz == '\'') {
            const char *close = strchr(tz + 1, '\'');
            if (!close)
                exit(parseerror(tz, "a ' that is not closed"));
            for (tz++; tz < close; tz++)
                PUT(*tz);
            tz++;
            w->bare = 0;
            if (!n)
                add_part(w, xmemdupz("", 0), 0, 1);
        } else if (*tz == '"') {
            FLUSH();
            w->bare = 0;
            add_part(w, xmemdupz("", 0), 0, 1);
            for (open = tz++; *tz != '"'; ) {
                if (!*tz)
                    exit(parseerror(open, "a \" that is not closed"));
                if (*tz == '$') {
                    FLUSH();
                    tz = add_variable(w, tz, 1);
                } else if (*tz == '\\' && strchr("\"$\\\n", tz[1])
                           && tz[1]) {
                    if (tz[1] != '\n')
                        PUT(tz[1]);
                    tz += 2;
                } else
                    PUT(*tz++);
            }
            FLUSH();
            tz++;
        } else if (*tz == '\\') {
            if (tz[1] == '\n')
                tz += 2;
            else if (!tz[1])
                exit(parseerror(tz, "a \\ at the end of the script"));
            else
                PUT(tz[1]), tz += 2, w->bare = 0;
        } else if (*tz == '$') {
            FLUSH();
            tz = add_variable(w, tz, 0);
        } else if (strchr("&|()<`", *tz)) {
            char errmsg[] = "? is not in crush: use sh -c";

            errmsg[0] = *tz;
            exit(parseerror(tz, errmsg));
        } else
            PUT(*tz++);
    }
    FLUSH();
    return tz;
}


/* Skip blanks, comments, and a backslash before a newline. */
static const char *
skip_blanks(const char *tz)
{
    for (;;) {
        if (blank((unsigned char) *tz))
            tz++;
        else if (*tz == '\\' && tz[1] == '\n')
            tz += 2;
        else if (*tz == '#')
            while (*tz && *tz != '\n')
                tz++;
        else
            return tz;
    }
}


/* If TZ starts an assignment, return the `=` after the name, or else
   NULL. */
static const char *
assignment(const char *tz)
{
    const char *p = tz;

    if (!(isalpha((unsigned char) *p) || *p == '_'))
        return NULL;
    while (name_char((unsigned char) *p))
        p++;
    return *p == '=' ? p : NULL;
}


/* Parse the value of an assignment at TZ into A: a word, or a list of
   words in `[...]`.  Return where the value ends. */
static const char *
parse_value(assign *a, const char *tz)
{
    if (*tz == '[') {
        for (tz = skip_blanks(tz + 1); *tz != ']'; tz = skip_blanks(tz)) {
            if (!*tz)
                exit(parseerror(tz, "a [ that is not closed"));
            if (*tz == '\n') {
                tz++;
                continue;
            }
            tz = parse_word(grow(&a->value, &a->n, sizeof *a->value), tz,
                           1);
            if (*tz == '>' || *tz == ';')
                exit(parseerror(tz, "a list has words and no more"));
        }
        return tz + 1;
    }
    if (*tz && !blank((unsigned char) *tz) && !strchr("\n;", *tz))
        tz = parse_word(grow(&a->value, &a->n, sizeof *a->value), tz, 0);
    return tz;
}


/* Parse the script at TZ, and append its commands to the array *C of *N. */
static void
parse(const char *tz, command **c, size_t *n)
{
    command *cmd = NULL;
    const char *digits;

    for (;;) {
        tz = skip_blanks(tz);
        if (!*tz || *tz == '\n' || *tz == ';') {
            cmd = NULL;
            if (!*tz)
                return;
            tz++;
            continue;
        }
        if (!cmd) {
            cmd = grow(c, n, sizeof **c);
            cmd->at = tz;
        }
        for (digits = tz; isdigit((unsigned char) *digits); )
            digits++;
        if (*digits == '>') {
            redirect *r = grow(&cmd->redirect, &cmd->nredirect,
                               sizeof *r);
            r->fd = digits == tz ? 1 : atoi(tz);
            r->append = digits[1] == '>';
            tz = skip_blanks(digits + 1 + r->append);
            if (!*tz || strchr("\n;>", *tz))
                exit(parseerror(tz,
                                "a redirection has the name of a file"));
            tz = parse_word(&r->target, tz, 0);
        } else if (!cmd->nword && assignment(tz)) {
            const char *eq = assignment(tz);
            assign *a = grow(&cmd->assign, &cmd->nassign, sizeof *a);
            a->name = xmemdupz(tz, (size_t) (eq - tz));
            tz = parse_value(a, eq + 1);
        } else {
            word *w = grow(&cmd->word, &cmd->nword, sizeof *w);
            const char *start = tz, **k;
            tz = parse_word(w, tz, 0);
            if (cmd->nword == 1 && w->bare && w->n == 1) {
                for (k = keywords; *k; k++)
                    if (!strcmp(*k, w->part[0].text))
                        exit(parseerror(start,
                                        "a keyword is not in "
                                        "crush"));
                if (!strcmp("{", w->part[0].text)
                    || !strcmp("}", w->part[0].text))
                    exit(parseerror(start,
                                    "a { or } that is a word "
                                    "is not in crush"));
            }
        }
    }
}


/* Expansion. */


static list
one(char *sz)
{
    list l;

    l.item = xrealloc(NULL, sizeof *l.item);
    l.item[0] = sz;
    l.n = 1;
    return l;
}


/* Count the bytes at the start of SZ that are blanks, when BLANKS is
   1, or that are not blanks, when BLANKS is 0. */
static size_t
span(const char *sz, int blanks)
{
    size_t n = 0;

    while (sz[n] && (strchr(" \t\n", sz[n]) != NULL) == blanks)
        n++;
    return n;
}


/* Return the value of the variable NAMEZ: the one the script set, or
   else the environment's.  The environment's is split at blanks into a
   list, unless QUOTED, when it stays one string, as it is. */
static list
lookup(const char *namez, int quoted)
{
    list l = {NULL, 0};
    const char *v;
    size_t i;

    for (i = nvars; i-- > 0; )
        if (!strcmp(vars[i].name, namez))
            return vars[i].value;
    if (!(v = getenv(namez)))
        return l;
    if (quoted)
        return one(xmemdupz(v, strlen(v)));
    while (*(v += span(v, 1))) {
        size_t len = span(v, 0);
        l.item = xrealloc(l.item, (l.n + 1) * sizeof *l.item);
        l.item[l.n++] = xmemdupz(v, len);
        v += len;
    }
    return l;
}


/* The items of L joined by a space. */
static char *
joinz(list l)
{
    size_t i, n = 0;
    char *s;

    for (i = 0; i < l.n; i++)
        n += strlen(l.item[i]) + 1;
    s = xrealloc(NULL, n + 1);
    for (n = 0, i = 0; i < l.n; i++) {
        if (i)
            s[n++] = ' ';
        n += (size_t) sprintf(s + n, "%s", l.item[i]);
    }
    s[n] = '\0';
    return s;
}


/* Join the lists A and B as two parts of one word.  A list of one item
   joins to each item of the other, lists of the same length join in
   pairs, and an empty list makes the result empty. */
static list
product(list a, list b, const char *at)
{
    list r;
    size_t i;

    if (!a.n || !b.n)
        return (list) {NULL, 0};
    if (a.n != 1 && b.n != 1 && a.n != b.n)
        exit(parseerror(at, "lists of different lengths are joined: "
                        "only a list of one is joined to a list"));
    r.n = a.n > b.n ? a.n : b.n;
    r.item = xrealloc(NULL, r.n * sizeof *r.item);
    for (i = 0; i < r.n; i++) {
        const char *x = a.item[a.n == 1 ? 0 : i],
            *y = b.item[b.n == 1 ? 0 : i];
        r.item[i] = xrealloc(NULL, strlen(x) + strlen(y) + 1);
        strcpy(r.item[i], x);
        strcat(r.item[i], y);
    }
    return r;
}


/* Expand the word W into a list. */
static list
expand(const word *w, const char *at)
{
    list r = one(xmemdupz("", 0));
    size_t i;

    for (i = 0; i < w->n; i++) {
        const part *p = &w->part[i];
        list l;
        if (!p->variable)
            l = one(p->text);
        else if (p->quoted)
            l = one(joinz(lookup(p->text, 1)));
        else
            l = lookup(p->text, 0);
        r = product(r, l, at);
    }
    return r;
}


/* Expand the N words at WORDS into one list. */
static list
expand_all(const word *words, size_t n, const char *at)
{
    list r = {NULL, 0}, l;
    size_t i, j;

    for (i = 0; i < n; i++) {
        l = expand(&words[i], at);
        for (j = 0; j < l.n; j++) {
            r.item = xrealloc(r.item, (r.n + 1) * sizeof *r.item);
            r.item[r.n++] = l.item[j];
        }
    }
    return r;
}


/* Running. */


static void
set(const char *namez, list value)
{
    size_t i;

    for (i = 0; i < nvars; i++)
        if (!strcmp(vars[i].name, namez)) {
            vars[i].value = value;
            return;
        }
    vars = xrealloc(vars, (nvars + 1) * sizeof *vars);
    vars[nvars].name = (char *) namez;
    vars[nvars++].value = value;
}


/* Wait for the process PID to end, and return its exit status, or 128
 * plus the number of the signal that killed it. */
static int
wait_for(pid_t pid)
{
    int s;

    while (waitpid(pid, &s, 0) < 0)
        if (errno != EINTR)
            return 1;
    return WIFEXITED(s) ? WEXITSTATUS(s) : 128 + WTERMSIG(s);
}


/* The builtin `embed NAME FILE`.  It writes C to the standard output
   that defines NAME_data, the bytes of FILE as one string literal with
   one line of C for each line of FILE, and NAME_size, the number of
   bytes.  A build uses it to turn a file into C.  It
   escapes only what C needs: a quote, a backslash, a question mark
   (which could start a trigraph), a newline, a tab, and, as three
   octal digits, every byte that is not printable. */
static int
embed(char **argv, size_t argc)
{
    const char *p;
    unsigned long n = 0;
    int c, bol = 1;
    FILE *in;

    if (argc != 3) {
        fprintf(stderr, "crush: embed: needs a name and a file\n");
        return 1;
    }
    for (p = argv[1]; *p; p++)
        if (!(isalpha((unsigned char) *p) || *p == '_'
              || (p > argv[1] && isdigit((unsigned char) *p)))) {
            fprintf(stderr, "crush: embed: %s is not a name in C\n",
                    argv[1]);
            return 1;
        }
    if (!*argv[1]) {
        fprintf(stderr, "crush: embed: a name in C is not empty\n");
        return 1;
    }
    if (!(in = fopen(argv[2], "rb"))) {
        fprintf(stderr, "crush: embed: %s: %s\n", argv[2],
                strerror(errno));
        return 1;
    }
    printf("const unsigned char %s_data[] =", argv[1]);
    while ((c = getc(in)) != EOF) {
        if (bol)
            fputs("\n    \"", stdout);
        bol = c == '\n';
        n++;
        if (c == '\n')
            fputs("\\n\"", stdout);
        else if (c == '\t')
            fputs("\\t", stdout);
        else if (c == '"' || c == '\\' || c == '?')
            printf("\\%c", c);
        else if (c >= ' ' && c <= '~')
            putchar(c);
        else
            printf("\\%03o", c);
    }
    if (!n)
        fputs("\n    \"\"", stdout);
    else if (!bol)
        putchar('"');
    printf(";\nconst unsigned long %s_size = %lu;\n", argv[1], n);
    fclose(in);
    return fflush(stdout) != 0;
}


/* The round constants of SHA-256: the first 32 bits of the fractional
   parts of the cube roots of the first 64 primes. */
static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b,
    0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
    0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7,
    0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152,
    0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
    0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
    0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
    0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
    0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};


/* Rotate X right by N bits. */
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))


/* Mix the 64 bytes at P into the state H. */
static void
sha256_block(uint32_t *h, const unsigned char *p)
{
    uint32_t w[64], v[8], t1, t2;
    int i;

    for (i = 0; i < 16; i++)
        w[i] = (uint32_t) p[4 * i] << 24 | (uint32_t) p[4 * i + 1] << 16
            | (uint32_t) p[4 * i + 2] << 8 | p[4 * i + 3];
    for (i = 16; i < 64; i++)
        w[i] = w[i - 16] + w[i - 7]
            + (ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3))
            + (ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10));
    memcpy(v, h, sizeof v);
    for (i = 0; i < 64; i++) {
        t1 = v[7] + (ROR(v[4], 6) ^ ROR(v[4], 11) ^ ROR(v[4], 25))
            + ((v[4] & v[5]) ^ (~v[4] & v[6])) + K[i] + w[i];
        t2 = (ROR(v[0], 2) ^ ROR(v[0], 13) ^ ROR(v[0], 22))
            + ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]));
        memmove(v + 1, v, 7 * sizeof *v);
        v[4] += t1;
        v[0] = t1 + t2;
    }
    for (i = 0; i < 8; i++)
        h[i] += v[i];
}


/* Write the SHA-256 sum of the bytes of IN to HEX, as 64 lowercase hex
   digits and a NUL.  Return 0, or -1 if reading IN fails. */
static int
sha256_sum(FILE *in, char *hex)
{
    uint32_t h[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    };
    unsigned char buf[64];
    uint64_t bits, total = 0;
    size_t n, fill = 0;
    int i;

    while ((n = fread(buf + fill, 1, sizeof buf - fill, in)) > 0) {
        total += n;
        if ((fill += n) == sizeof buf) {
            sha256_block(h, buf);
            fill = 0;
        }
    }
    if (ferror(in))
        return -1;

    /* A 1 bit, then 0 bits to 8 bytes short of a block, then the number
       of bits as 8 bytes, big end first. */
    buf[fill++] = 0x80;
    if (fill > 56) {
        memset(buf + fill, 0, sizeof buf - fill);
        sha256_block(h, buf);
        fill = 0;
    }
    memset(buf + fill, 0, 56 - fill);
    for (bits = total * 8, i = 0; i < 8; i++)
        buf[56 + i] = (unsigned char) (bits >> (56 - 8 * i));
    sha256_block(h, buf);
    for (i = 0; i < 8; i++)
        sprintf(hex + 8 * i, "%08lx", (unsigned long) h[i]);
    return 0;
}


/* The builtin `sha256 FILE...`.  It writes the SHA-256 sum of each FILE
   to the standard output, as `HASH  FILE`, the way sha256sum does, so
   that a build can check what it fetched without a tool for it.  It
   goes on after a file it cannot read, and returns 1 if there was one. */
static int
sha256(char **argv, size_t argc)
{
    char hex[65];
    FILE *in;
    size_t i;
    int failed = 0;

    if (argc < 2) {
        fprintf(stderr, "crush: sha256: needs a file\n");
        return 1;
    }
    for (i = 1; i < argc; i++) {
        if (!(in = fopen(argv[i], "rb")) || sha256_sum(in, hex)) {
            fprintf(stderr, "crush: sha256: %s: %s\n", argv[i],
                    strerror(errno));
            failed = 1;
        } else
            printf("%s  %s\n", hex, argv[i]);
        if (in)
            fclose(in);
    }
    return fflush(stdout) != 0 || failed;
}


/* Whether the word W needs quotes to be read back as one word. */
static int
needs_quotes(const char *w)
{
    if (!*w)
        return 1;
    for (; *w; w++)
        if (!isalnum((unsigned char) *w) && !strchr("_@%+=:,./-", *w))
            return 1;
    return 0;
}


/* Write the words of ARGV after the first on stderr, behind a "% ", with
   quotes around each word that needs them, so that the line can be
   pasted into a shell. */
static void
show(list argv)
{
    size_t i;
    const char *w;

    fputs("%", stderr);
    for (i = 1; i < argv.n; i++) {
        fputc(' ', stderr);
        if (!needs_quotes(argv.item[i])) {
            fputs(argv.item[i], stderr);
            continue;
        }
        fputc('\'', stderr);
        for (w = argv.item[i]; *w; w++)
            if (*w == '\'')
                fputs("'\\''", stderr);
            else
                fputc(*w, stderr);
        fputc('\'', stderr);
    }
    fputc('\n', stderr);
}


/* Run the command C, and return its status. */
static int
run(const command *c)
{
    list argv = expand_all(c->word, c->nword, c->at);
    pid_t pid;
    size_t i;

    if (!argv.n)
        return 0;
    if (!strcmp(argv.item[0], "run")) {
        show(argv);
        if (argv.n == 1)
            return 0;
        memmove(argv.item, argv.item + 1, --argv.n * sizeof *argv.item);
    }
    if (!strcmp(argv.item[0], "cd")) {
        const char *dir = argv.n > 1 ? argv.item[1] : getenv("HOME");
        if (argv.n > 2 || !dir || chdir(dir)) {
            fprintf(stderr, "crush: cd: %s\n",
                    argv.n > 2 ? "too many arguments"
                    : dir ? strerror(errno) : "no HOME");
            return 1;
        }
        return 0;
    }
    if (!strcmp(argv.item[0], "exit")) {
        if (argv.n > 2) {
            fprintf(stderr, "crush: exit: too many arguments\n");
            return 1;
        }
        exit(argv.n == 2 ? atoi(argv.item[1]) : status);
    }

    fflush(NULL);
    if ((pid = fork()) < 0) {
        fprintf(stderr, "crush: %s: %s\n", argv.item[0],
                strerror(errno));
        return 1;
    }
    if (pid == 0) {
        for (i = 0; i < c->nassign; i++) {
            list v = expand_all(c->assign[i].value, c->assign[i].n,
                                c->at);
            setenv(c->assign[i].name, joinz(v), 1);
        }
        for (i = 0; i < c->nredirect; i++) {
            list target = expand(&c->redirect[i].target, c->at);
            int fd;
            if (target.n != 1) {
                fprintf(stderr, "crush: a redirection has one file\n");
                _exit(1);
            }
            fd = open(target.item[0],
                      O_WRONLY | O_CREAT | (c->redirect[i].append
                                            ? O_APPEND : O_TRUNC),
                                                0666);
            if (fd < 0 || dup2(fd, c->redirect[i].fd) < 0) {
                fprintf(stderr, "crush: %s: %s\n", target.item[0],
                        strerror(errno));
                _exit(1);
            }
            if (fd != c->redirect[i].fd)
                close(fd);
        }
        if (!strcmp(argv.item[0], "embed"))
            _exit(embed(argv.item, argv.n));
        if (!strcmp(argv.item[0], "sha256"))
            _exit(sha256(argv.item, argv.n));
        argv.item = xrealloc(argv.item, (argv.n
                                         + 1) * sizeof *argv.item);
        argv.item[argv.n] = NULL;
        execvp(argv.item[0], argv.item);
        fprintf(stderr, "crush: %s: %s\n", argv.item[0],
                strerror(errno));
        _exit(errno == ENOENT ? 127 : 126);
    }
    return wait_for(pid);
}


int
main(int argc, char **argv)
{
    command *c = NULL;
    size_t n = 0, i, j;
    FILE *f;
    char *buf;
    long size = 0;

    if (argc != 2)
        argfatal("usage: crush FILE");
    script_name = argv[1];
    if (!(f = fopen(argv[1], "rb")) || fseek(f, 0, SEEK_END)
        || (size = ftell(f)) < 0 || fseek(f, 0, SEEK_SET))
        sysfatal(argv[1]);
    buf = xrealloc(NULL, (size_t) size + 1);
    if (fread(buf, 1, (size_t) size, f) != (size_t) size)
        sysfatal(argv[1]);
    buf[size] = '\0';
    fclose(f);
    text = buf;
    if (strlen(text) != (size_t) size)
        exit(parseerror(text + strlen(text),
                        "a NUL is not in a script"));

    parse(text, &c, &n);
    for (i = 0; i < n; i++) {
        if (!c[i].nword) {
            for (j = 0; j < c[i].nassign; j++)
                set(c[i].assign[j].name,
                    expand_all(c[i].assign[j].value, c[i].assign[j].n,
                               c[i].at));
            continue;
        }
        if ((status = run(&c[i])) != 0)
            return status;
    }
    return 0;
}
