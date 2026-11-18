# Run from the repository root:
#   docker buildx bake -f docker/docker-bake.hcl

variable "REGISTRY"   { default = "xoseperez/chirpstack-gateway-mesh" }
variable "VERSION"    { default = "dev" }
# Comma-separated extra tags; CI passes "X.Y.Z,X.Y,X,latest" for the newest release.
variable "EXTRA_TAGS" { default = "" }
variable "REVISION"   { default = "" }
# Where the repository files the image copies (the region files) are taken from.
# Locally that's the working tree; CI points it at a checkout of the release tag,
# so they match the binaries even when docker/ comes from a newer branch.
variable "SOURCE"     { default = "." }

target "default" {
  context   = "docker"
  contexts  = {
    dist          = "dist"
    configuration = "${SOURCE}/configuration"
  }
  platforms = ["linux/amd64", "linux/arm64", "linux/arm/v7"]
  tags = concat(
    ["${REGISTRY}:${VERSION}"],
    [for t in split(",", EXTRA_TAGS) : "${REGISTRY}:${t}" if t != ""]
  )
  labels = {
    "org.opencontainers.image.title"    = "ChirpStack Gateway Mesh"
    "org.opencontainers.image.source"   = "https://github.com/xoseperez/chirpstack-gateway-mesh"
    "org.opencontainers.image.version"  = VERSION
    "org.opencontainers.image.revision" = REVISION
  }
}
