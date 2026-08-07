import sys

p = '/root/linux-7.1.3-inst/tools/objtool/klp-diff.c'
s = open(p).read()

# 1) export->mod basename
old1 = 'export->mod = strdup(mod);'
new1 = 'export->mod = strdup(basename(mod));'
print('1:', old1 in s)
s = s.replace(old1, new1)

# 2) __find_modname env override
needle = 'static const char *__find_modname(struct elfs *e)\n{\n\tstruct section *sec;\n\tchar *name;\n\n\tsec = find_section_by_name'
print('2:', needle in s)
if needle in s:
    repl = 'static const char *__find_modname(struct elfs *e)\n{\n\tstruct section *sec;\n\tchar *name;\n\tconst char *env = getenv("KLP_OBJNAME");\n\n\tif (env)\n\t\treturn env;\n\n\tsec = find_section_by_name'
    s = s.replace(needle, repl)

# 3) includes
if '#include <libgen.h>' not in s:
    s = s.replace('#include <stdio.h>', '#include <stdio.h>\n#include <libgen.h>\n#include <stdlib.h>')

open(p, 'w').write(s)
print('done')
