################################################################################
#
# drobo-samba: Samba 4 for the DroboFS (SMB2/SMB3), self-contained in a DroboApp
#
# Derived from Buildroot's package/samba4. Differences:
#   - installs under the DroboApp prefix (non-FHS) so compiled-in paths such as
#     samba-dcerpcd, VFS modules and private libs resolve on the device
#   - file-server only: no AD, no LDAP, no winbind, no ctdb, no python, no printing
#   - cross-answers tuned for the 2.6.22 kernel (no OFD locks, no RW hints)
#
################################################################################

DROBO_SAMBA_VERSION = 4.23.8
DROBO_SAMBA_SITE = https://download.samba.org/pub/samba/stable
DROBO_SAMBA_SOURCE = samba-$(DROBO_SAMBA_VERSION).tar.gz
DROBO_SAMBA_LICENSE = GPL-3.0+
DROBO_SAMBA_LICENSE_FILES = COPYING
DROBO_SAMBA_PREFIX = $(call qstrip,$(BR2_PACKAGE_DROBO_SAMBA_PREFIX))
DROBO_SAMBA_DEPENDENCIES = \
	host-e2fsprogs host-flex host-heimdal host-nfs-utils \
	host-perl host-perl-parse-yapp host-python3 \
	cmocka e2fsprogs gnutls popt zlib \
	$(if $(BR2_PACKAGE_LIBAIO),libaio) \
	$(if $(BR2_PACKAGE_READLINE),readline) \
	$(TARGET_NLS_DEPENDENCIES)
DROBO_SAMBA_CFLAGS = $(TARGET_CFLAGS)
DROBO_SAMBA_LDFLAGS = $(TARGET_LDFLAGS) $(TARGET_NLS_LIBS)
DROBO_SAMBA_CONF_ENV = \
	CFLAGS="$(DROBO_SAMBA_CFLAGS)" \
	LDFLAGS="$(DROBO_SAMBA_LDFLAGS)" \
	XSLTPROC=false \
	WAF_NO_PREFORK=1
DROBO_SAMBA_PYTHON = PYTHON="$(HOST_DIR)/bin/python3"

DROBO_SAMBA_SHARED_MODULES = !vfs_snapper !idmap_ad

ifeq ($(BR2_PACKAGE_LIBICONV),y)
DROBO_SAMBA_DEPENDENCIES += libiconv
DROBO_SAMBA_LDFLAGS += -liconv
endif

ifeq ($(BR2_PACKAGE_LIBTIRPC),y)
DROBO_SAMBA_CFLAGS += `$(PKG_CONFIG_HOST_BINARY) --cflags libtirpc`
DROBO_SAMBA_LDFLAGS += `$(PKG_CONFIG_HOST_BINARY) --libs libtirpc`
DROBO_SAMBA_DEPENDENCIES += libtirpc host-pkgconf
endif

define DROBO_SAMBA_CONFIGURE_CMDS
	$(INSTALL) -m 0644 $(DROBO_SAMBA_PKGDIR)/drobo-samba-cache.txt $(@D)/cache.txt;
	echo 'Checking uname machine type: $(BR2_ARCH)' >>$(@D)/cache.txt;
	(cd $(@D); \
		$(DROBO_SAMBA_PYTHON) \
		python_LDFLAGS="" \
		python_LIBDIR="" \
		PERL="$(HOST_DIR)/bin/perl" \
		$(TARGET_CONFIGURE_OPTS) \
		$(DROBO_SAMBA_CONF_ENV) \
		./configure \
			--prefix=$(DROBO_SAMBA_PREFIX) \
			--sysconfdir=$(DROBO_SAMBA_PREFIX)/etc \
			--localstatedir=$(DROBO_SAMBA_PREFIX)/var \
			--with-privatedir=$(DROBO_SAMBA_PREFIX)/var/private \
			--with-lockdir=$(DROBO_SAMBA_PREFIX)/var/lock \
			--with-piddir=$(DROBO_SAMBA_PREFIX)/var/run \
			--with-logfilebase=$(DROBO_SAMBA_PREFIX)/var/log \
			--with-sockets-dir=$(DROBO_SAMBA_PREFIX)/var/run \
			--with-libiconv=$(STAGING_DIR)/usr \
			--cross-compile \
			--cross-answers=$(@D)/cache.txt \
			--hostcc=gcc \
			--disable-rpath \
			--disable-rpath-install \
			--disable-python \
			--disable-iprint \
			--disable-cups \
			--disable-avahi \
			--disable-glusterfs \
			--disable-cephfs \
			--disable-spotlight \
			--without-ad-dc \
			--without-ads \
			--without-ldap \
			--without-json \
			--without-winbind \
			--without-systemd \
			--without-fam \
			--without-pam \
			--without-dmapi \
			--without-gpgme \
			--without-quotas \
			--without-acl-support \
			--without-libarchive \
			--without-libunwind \
			--without-regedit \
			--without-ldb-lmdb \
			--without-cluster-support \
			--bundled-libraries='!asn1_compile,!compile_et' \
			--with-shared-modules=$(subst $(space),$(comma),$(strip $(DROBO_SAMBA_SHARED_MODULES))) \
	)
endef

define DROBO_SAMBA_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(DROBO_SAMBA_PYTHON) $(MAKE) -C $(@D)
endef

define DROBO_SAMBA_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(DROBO_SAMBA_PYTHON) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
	rm -f $(TARGET_DIR)$(DROBO_SAMBA_PREFIX)/bin/smbtorture
	rm -rf $(TARGET_DIR)$(DROBO_SAMBA_PREFIX)/include \
		$(TARGET_DIR)$(DROBO_SAMBA_PREFIX)/lib/pkgconfig \
		$(TARGET_DIR)$(DROBO_SAMBA_PREFIX)/share/man
endef

$(eval $(generic-package))
