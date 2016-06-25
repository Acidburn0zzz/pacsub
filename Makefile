PERL_VENDORLIB != perl -MConfig -e 'print $$Config{vendorlib}'

PREFIX := /usr
DESTDIR :=
BINDIR := $(PREFIX)/bin

PKGNAME = pacsub
PKGVER != grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} .* \([0-9.][0-9.]+\)$$' ChangeLog \
          | sed -e 's/^.*(//;s/)$$//'
DISTDIR := $(PKGNAME)-$(PKGVER)

DISTFILES := \
	ChangeLog LICENSE \
	Makefile \
	pacsub-manage \
	PacSub/AccessControl.pm \
	PacSub/CLI.pm \
	PacSub/Config.pm \
	PacSub/Gpg.pm \
	PacSub/Package.pm \
	PacSub/Repo.pm \
	PacSub/Tools.pm \
	PacSub/User.pm \


all:

.PHONY: version
version:
	@echo $(PKGVER)

.PHONY: dist
dist:
	mkdir $(DISTDIR)
	mkdir $(DISTDIR)/PacSub
	cp ChangeLog LICENSE Makefile $(DISTDIR)/
	cp pacsub-manage $(DISTDIR)/
	cp PacSub/*.pm $(DISTDIR)/PacSub/
	tar czvf $(DISTDIR).tar.gz $(DISTDIR)
	rm -rf $(DISTDIR)

.PHONY: install
install:
	install -dm755 $(DESTDIR)$(PERL_VENDORLIB)/PacSub
	install -m644 PacSub/AccessControl.pm $(DESTDIR)$(PERL_VENDORLIB)/PacSub/
	install -m644 PacSub/CLI.pm           $(DESTDIR)$(PERL_VENDORLIB)/PacSub/
	install -m644 PacSub/Config.pm        $(DESTDIR)$(PERL_VENDORLIB)/PacSub/
	install -m644 PacSub/Gpg.pm           $(DESTDIR)$(PERL_VENDORLIB)/PacSub/
	install -m644 PacSub/Package.pm       $(DESTDIR)$(PERL_VENDORLIB)/PacSub/
	install -m644 PacSub/Repo.pm          $(DESTDIR)$(PERL_VENDORLIB)/PacSub/
	install -m644 PacSub/Tools.pm         $(DESTDIR)$(PERL_VENDORLIB)/PacSub/
	install -m644 PacSub/User.pm          $(DESTDIR)$(PERL_VENDORLIB)/PacSub/
	install -dm755 $(DESTDIR)$(BINDIR)
	install -m755 pacsub-manage $(DESTDIR)$(BINDIR)/pacsub-manage
