################################################################################
#
# docker-compose-v1
#
################################################################################

DOCKER_COMPOSE_V1_VERSION = 1.29.2
DOCKER_COMPOSE_V1_SOURCE = docker-compose-Linux-aarch64
DOCKER_COMPOSE_V1_SITE = https://github.com/docker/compose/releases/download/$(DOCKER_COMPOSE_V1_VERSION)
DOCKER_COMPOSE_V1_LICENSE = Apache-2.0

define DOCKER_COMPOSE_V1_EXTRACT_CMDS
	cp $(DOCKER_COMPOSE_V1_DL_DIR)/$(DOCKER_COMPOSE_V1_SOURCE) $(@D)/docker-compose
endef

define DOCKER_COMPOSE_V1_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/docker-compose $(TARGET_DIR)/usr/bin/docker-compose
endef

$(eval $(generic-package))
