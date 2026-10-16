#!/usr/bin/env python3
"""List the external commands that a shell script calls (host test helper).

Usage: preflight-scan.py FILE...
Prints "FILE: cmd cmd ..." for each file. A command is a word in command
position that is not a shell builtin, a keyword or a function that one of the
FILEs defines. The scan is a text scan, not a shell parser. It drops
comments, here-document bodies and quoted text, but it keeps the command
substitutions inside quotes. It is made for the style of the installer
scripts. test-preflight.sh uses it to find a command that
installer/lib/tsx-preflight.sh does not list. A command that a script only
puts into a string (for example MSSH="sshpass -e ssh ...") is not in command
position: the scan finds ssh, sshpass and scp there with a second pattern.
"""
import re
import sys

BUILTINS = set("""
. : [ [[ alias bg bind break builtin caller cd command compgen complete continue declare dirs disown echo enable
eval exec exit export false fc fg getopts hash help history jobs kill let local logout popd printf pushd pwd read readonly
return set shift shopt source suspend test times trap true type typeset ulimit umask unalias unset wait
if then else elif fi for while until do done case esac in select function time coproc
""".split())


def skeleton(text):
    """Return the code of TEXT without comments, here-documents and quoted text."""
    out = []
    i, n = 0, len(text)
    pending = []  # here-document terminators that wait for the next newline

    def sub_commands(s):
        """Command substitutions inside the string S, as code."""
        res, j = [], 0
        while j < len(s):
            if s.startswith("$(", j):
                d, k = 0, j + 1
                while k < len(s):
                    if s[k] == "(":
                        d += 1
                    elif s[k] == ")":
                        d -= 1
                        if d == 0:
                            break
                    k += 1
                inner = s[j + 2:k]
                if inner.startswith("("):  # arithmetic: look inside it
                    res.append(sub_commands(inner))
                else:
                    res.append(skeleton(inner))
                j = k + 1
            elif s[j] == "`":
                k = s.find("`", j + 1)
                k = len(s) if k < 0 else k
                res.append(skeleton(s[j + 1:k]))
                j = k + 1
            elif s[j] == "\\":
                j += 2
            else:
                j += 1
        return " ; ".join(r for r in res if r.strip())

    while i < n:
        c = text[i]
        if c == "\\":
            out.append(" ")
            i += 2
        elif c == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
            while i < n and text[i] != "\n":
                i += 1
        elif c == "'":
            k = text.find("'", i + 1)
            k = n - 1 if k < 0 else k
            out.append("''")
            i = k + 1
        elif c == '"':
            k = i + 1
            while k < n and text[k] != '"':
                if text[k] == "\\":
                    k += 2
                elif text.startswith("$(", k):
                    d, k2 = 0, k + 1
                    while k2 < n:
                        if text[k2] == "(":
                            d += 1
                        elif text[k2] == ")":
                            d -= 1
                            if d == 0:
                                break
                        k2 += 1
                    k = k2 + 1
                else:
                    k += 1
            body = text[i + 1:k]
            out.append(" ; " + sub_commands(body) + " ; ")
            i = k + 1
        elif text.startswith("${", i):
            d, k = 0, i + 1
            while k < n:
                if text[k] == "{":
                    d += 1
                elif text[k] == "}":
                    d -= 1
                    if d == 0:
                        break
                k += 1
            out.append("V")
            i = k + 1
        elif text.startswith("<<", i) and not text.startswith("<<<", i):
            m = re.match(r"<<-?\s*(?:'([A-Za-z_]+)'|\"([A-Za-z_]+)\"|\\?([A-Za-z_]+))", text[i:])
            term = m and (m.group(1) or m.group(2) or m.group(3))
            ls = text.rfind("\n", 0, i) + 1
            if term and "((" not in text[ls:i] and re.search(r"\n[ \t]*" + term + r"[ \t]*(?:\n|$)", text[i:]):
                pending.append(term)
                i += m.end()
            else:
                out.append(c)
                i += 1
        elif c == "\n":
            out.append("\n")
            i += 1
            while pending:
                term = pending.pop(0)
                while i < n:
                    e = text.find("\n", i)
                    e = n if e < 0 else e
                    line = text[i:e].strip()
                    i = e + 1
                    if line == term:
                        break
        else:
            out.append(c)
            i += 1
    return "".join(out)


KW = r"(?:(?:if|then|do|else|elif|while|until|time|!)\s+)*"
CMDSTART = re.compile(
    r"(?:^|;|&&|\|\||\||\(|\$\(|`|\{\s|\bthen\b|\bdo\b|\belse\b|\bif\b|\belif\b|\bwhile\b|\buntil\b)\s*"
    + KW + r"((?:[A-Za-z_][A-Za-z0-9_]*=[^\s$`()]*\s+)*)([a-z][a-z0-9._+-]*)(?![=A-Za-z0-9_.+-])")
CASEPAT = re.compile(r"(?:^|;;)\s*(?:\(\s*)?[^\s()|;]+(?:\|[^\s()|;]+)*\)\s*")
WRAPPER = re.compile(r"\b(xargs|exec|nohup|setsid|env|timeout)\b((?:\s+\S+){0,8})")
NETWORD = re.compile(r"\b(sshpass|ssh|scp)\s+-[A-Za-z]")


def scan(files):
    texts = {f: open(f, errors="replace").read() for f in files}
    funcs = set()
    for t in texts.values():
        funcs |= set(re.findall(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)", t, re.M))
    res = {}
    for f, t in texts.items():
        found = set()
        for s in skeleton(t).split("\n"):
            s = CASEPAT.sub(" ; ", s)
            for m in CMDSTART.finditer(s):
                w = m.group(2)
                if w not in BUILTINS and w not in funcs:
                    found.add(w)
            for m in WRAPPER.finditer(s):
                toks = m.group(2).split()
                if m.group(1) == "timeout":
                    while toks and toks[0].startswith("-"):
                        toks.pop(0)
                    toks = toks[1:]
                while toks and re.match(r"^(-|\d+$|\{\}$|[A-Za-z_]+=)", toks[0]):
                    toks.pop(0)
                if toks and re.match(r"^[a-z][a-z0-9._+-]*$", toks[0]) and toks[0] not in BUILTINS and toks[0] not in funcs:
                    found.add(toks[0])
        for line in t.split("\n"):
            if not line.strip().startswith("#"):
                found.update(m.group(1) for m in NETWORD.finditer(line))
        res[f] = found
    return res


if __name__ == "__main__":
    for f, c in scan(sys.argv[1:]).items():
        print("%s: %s" % (f, " ".join(sorted(c))))
