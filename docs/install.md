# Install, update, pin

This repository is its own marketplace: `.claude-plugin/marketplace.json`
lists the `prometheus-exporter` plugin with this repository as its source.

## Install

```
/plugin marketplace add SckyzO/prometheus-exporter-plugin
/plugin install prometheus-exporter@prometheus-exporter-marketplace
```

## Update

```
/plugin marketplace update prometheus-exporter-marketplace
```

This refreshes the marketplace listing from its source. **If you pinned the
marketplace to a tag, `update` will not move you off it**: it re-fetches at
the same ref. See [Pinning](#pinning-a-version) below.

## Uninstall

```
/plugin uninstall prometheus-exporter@prometheus-exporter-marketplace
```

## Pinning a version

Every release is tagged `vX.Y.Z`. To pin the install to a specific tag
instead of whatever the marketplace currently points to, add the marketplace
via its full git URL with the tag appended as a `#` ref:

```
/plugin marketplace add https://github.com/SckyzO/prometheus-exporter-plugin.git#v0.9.0
```

### Getting back off a pin

A pin is sticky, and nothing in the UI says so. A pinned marketplace keeps
reporting its pinned release as the latest one available, because at that ref
it is: `/plugin` will answer *"already at the latest version (0.6.0)"* long
after 0.8.0 shipped, and `/plugin marketplace update` will not help.

To check whether you are pinned, look for a `ref` under your marketplace in
`~/.claude/plugins/known_marketplaces.json`:

```json
"prometheus-exporter-marketplace": {
  "source": { "source": "git", "url": "...", "ref": "v0.6.0" }
}
```

A `ref` there means pinned. To move to a different pin, or to stop tracking a
tag and follow the default branch instead, remove the marketplace and add it
again:

```
/plugin marketplace remove prometheus-exporter-marketplace
/plugin marketplace add SckyzO/prometheus-exporter-plugin
/plugin install prometheus-exporter@prometheus-exporter-marketplace
```

The short `owner/repo` form carries no ref, so it follows the default branch.
Use the `...git#vX.Y.Z` form instead if you want to stay pinned, at a newer
tag.

## Sharing with a team

Declare the marketplace and enable the plugin for every collaborator by
adding both to the repository's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "prometheus-exporter-marketplace": {
      "source": {
        "source": "github",
        "repo": "SckyzO/prometheus-exporter-plugin"
      }
    }
  },
  "enabledPlugins": {
    "prometheus-exporter@prometheus-exporter-marketplace": true
  }
}
```

Collaborators who trust the repository folder are then prompted to install
the marketplace and the plugin automatically.

## Before you install anything

Installing a plugin means trusting its source: plugins run with your own user
privileges and can execute arbitrary code on your machine. Only add
marketplaces and install plugins from sources you trust, and check what a
plugin contains before installing it.
