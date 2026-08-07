p = '/root/linux-7.1.3-inst/scripts/Makefile.modpost'
s = open(p).read()
if 'modpost-args += -N' not in s:
    s = s.replace('modpost-args += -n', 'modpost-args += -n\nmodpost-args += -N')
    open(p, 'w').write(s)
    print('added -N')
else:
    print('already there')
