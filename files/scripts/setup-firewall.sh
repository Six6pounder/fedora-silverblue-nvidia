#!/usr/bin/env bash

# Open the firewalld ports Sunshine needs for Moonlight clients to pair and
# stream. The "sunshine" service definition itself ships read-only under
# /usr/lib/firewalld/services/sunshine.xml (via the files module), but a service
# only takes effect once it is added to a zone -- firewalld has no auto-enable.
#
# We add it with firewall-offline-cmd at build time rather than shipping a static
# zone file so the base image's own default-zone services (ssh, mdns,
# dhcpv6-client, ...) are preserved as-is and merged with ours, instead of being
# frozen to whatever they happen to be today.

set -euo pipefail

# Add to the image's default zone (public on this base) so it applies to the
# normal network profile without the user having to pick a zone.
zone="$(firewall-offline-cmd --get-default-zone)"

firewall-offline-cmd --zone="${zone}" --add-service=sunshine

echo "Added 'sunshine' firewalld service to the '${zone}' zone."
