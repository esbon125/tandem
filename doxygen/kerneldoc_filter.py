#!/usr/bin/env python3
"""Doxygen INPUT_FILTER for the C sources: kernel-doc in, Doxygen out.

The driver follows the kernel's own comment conventions, which Doxygen does
not read: kernel-doc blocks (`struct x - brief`, `@member: text`, `Return:`)
and plain `/* ... */` comments right above a declaration. The sources stay
as they are; Doxygen sees this translation, line for line, so its line
numbers still match the file.
"""

import re
import sys

HEAD = re.compile(r"^(\s*\*\s*)(?:(?:struct|union|enum)\s+)?[\w]+(?:\(\))?\s+-\s+(.*)$")
FIELD = re.compile(r"^(\s*\*\s*)@(\w+):\s*(.*)$")
RETURN = re.compile(r"^(\s*\*\s*)Returns?:\s*(.*)$")
INLINE = re.compile(r"(?<![\w@\\])@(\w+)")


def translate(lines):
    out = list(lines)
    i = 0
    while i < len(out):
        line = out[i]
        stripped = line.lstrip()
        if not stripped.startswith("/*") or "SPDX-License-Identifier" in line:
            i += 1
            continue
        end = i
        while "*/" not in out[end] and end + 1 < len(out):
            end += 1
        following = out[end + 1].strip() if end + 1 < len(out) else ""
        kerneldoc = stripped.startswith("/**")
        precedes_decl = following and not following.startswith(("#", "}", "/*", "//"))
        if kerneldoc or precedes_decl:
            if not kerneldoc:
                out[i] = line.replace("/*", "/**", 1)
            is_struct = False
            # kernel-doc's inline form, `/** @member: text */` above a struct
            # member, or `@arg: text` opening a function's comment
            first = re.match(r"^(\s*/\*\*\s*)@(\w+):\s*(.*)$", out[i])
            if first:
                lead, name, rest = first.groups()
                rest = INLINE.sub(r"@p \1", rest)
                if "(" in following:
                    out[i] = f"{lead}@param {name} {rest}\n"
                else:
                    out[i] = f"{lead}{rest}\n"
            for k in range(i, end + 1):
                text = out[k]
                if k == i + 1 and kerneldoc:
                    m = HEAD.match(text)
                    if m:
                        is_struct = bool(re.match(r"\s*\*\s*(struct|union|enum)\s", text))
                        out[k] = f"{m.group(1)}@brief {m.group(2)}\n"
                        continue
                m = FIELD.match(text)
                if m:
                    rest = INLINE.sub(r"@p \1", m.group(3))
                    if is_struct:
                        out[k] = f"{m.group(1)}- @c {m.group(2)}: {rest}\n"
                    else:
                        out[k] = f"{m.group(1)}@param {m.group(2)} {rest}\n"
                    continue
                m = RETURN.match(text)
                if m:
                    out[k] = f"{m.group(1)}@return {m.group(2)}\n"
                    continue
                if k > i or not first:
                    out[k] = INLINE.sub(r"@p \1", text)
        i = end + 1
    return out


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as f:
        sys.stdout.write("".join(translate(f.readlines())))
