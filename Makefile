all:
	@echo No build steps

install:
	mkdir -p ${DESTDIR}/usr/bin/
	echo "zxcvasdf" > ${DESTDIR}/usr/bin/qwer
