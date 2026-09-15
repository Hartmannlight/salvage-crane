# Restic dependency overlay

The Docker build uses the tagged upstream source with these go.mod/go.sum files.
They update vulnerable transitive dependencies that the upstream release binary
still bundles. Renovate maintains Go versions and the compiler image. For a new
Restic release, regenerate the overlay from that release and retain the security
updates; the real backup/restore and image tests must pass before promotion.
