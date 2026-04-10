## asset_vfs.nim
## VFS merge model for assets/ and scripts/ plugin folders.
## "Last plugin in load order wins on same basename."

import std/[os, strutils, tables, sequtils, algorithm]
import plugin_db

type
  AssetKind* = enum
    akImage,   ## .png .jpg .jpeg .webp  — from assets/
    akSound,   ## .ogg .wav .mp3 .flac   — from assets/
    akScript,  ## anything in scripts/   — determined by source folder
    akOther    ## other files in assets/

  AssetProvider* = object
    pluginName*:   string
    pluginFolder*: string
    fullPath*:     string

  AssetEntry* = object
    basename*:     string
    kind*:         AssetKind
    winning*:      AssetProvider
    allProviders*: seq[AssetProvider]   ## index 0 = lowest priority

  AssetVFS* = object
    entries*:     Table[string, AssetEntry]
    pluginFiles*: Table[string, seq[string]]  ## pluginFolder → sorted abs paths

proc assetKind*(path: string): AssetKind =
  let ext = splitFile(path).ext.toLowerAscii
  case ext
  of ".png", ".jpg", ".jpeg", ".webp": akImage
  of ".ogg", ".wav", ".mp3", ".flac":  akSound
  else:                                akOther

proc addEntry(vfs: var AssetVFS; bn: string; kind: AssetKind;
              prov: AssetProvider) =
  if vfs.entries.hasKey(bn):
    vfs.entries[bn].allProviders.add prov
    vfs.entries[bn].winning = prov
  else:
    vfs.entries[bn] = AssetEntry(
      basename:     bn,
      kind:         kind,
      winning:      prov,
      allProviders: @[prov])

proc buildVFS*(plugins: seq[PluginEntry]): AssetVFS =
  ## Build merged VFS from enabled plugins in load order.
  ## Last plugin wins on basename collision.
  for e in plugins:
    var files: seq[string]

    if e.toolId == "assets":
      ## Dedicated assets plugin: the plugin folder IS the asset root.
      ## Walk it directly, skipping JSON metadata files.
      ## Files inside a scripts/ subdir are always akScript regardless of extension.
      let scriptsDir = e.folder / "scripts"
      for fp in walkDirRec(e.folder):
        if fp.endsWith(".json"): continue
        files.add fp
        let kind = if fp.startsWith(scriptsDir): akScript else: assetKind(fp)
        addEntry(result, lastPathPart(fp), kind,
                 AssetProvider(pluginName: e.name, pluginFolder: e.folder,
                               fullPath: fp))
    else:
      ## Regular plugin: may have an optional assets/ and/or scripts/ subfolder.
      let assetsDir  = e.folder / "assets"
      let scriptsDir = e.folder / "scripts"

      if dirExists(assetsDir):
        for fp in walkDirRec(assetsDir):
          files.add fp
          addEntry(result, lastPathPart(fp), assetKind(fp),
                   AssetProvider(pluginName: e.name, pluginFolder: e.folder,
                                 fullPath: fp))

      if dirExists(scriptsDir):
        for fp in walkDirRec(scriptsDir):
          files.add fp
          addEntry(result, lastPathPart(fp), akScript,
                   AssetProvider(pluginName: e.name, pluginFolder: e.folder,
                                 fullPath: fp))

    result.pluginFiles[e.folder] = sorted(files)

proc assetBasenames*(vfs: AssetVFS; kind: AssetKind): seq[string] =
  ## Return sorted basenames of all VFS entries of the given kind.
  for bn, e in vfs.entries:
    if e.kind == kind: result.add bn
  result.sort()

proc pluginBasenames*(vfs: AssetVFS; pluginFolder: string;
                      kind: AssetKind): seq[string] =
  ## Return sorted basenames contributed by a specific plugin folder.
  for fp in vfs.pluginFiles.getOrDefault(pluginFolder, @[]):
    let bn = lastPathPart(fp)
    if vfs.entries.hasKey(bn) and vfs.entries[bn].kind == kind:
      result.add bn
  result = result.deduplicate(isSorted = false)
  result.sort()
