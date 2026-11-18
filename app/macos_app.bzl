"""macos_app: the Review Map app bundle, put together from executables Bazel builds.

It makes the layout `tauri build` makes for this app (see tauri.conf.json), without the Tauri CLI:

    <bundle_name>.app/Contents/Info.plist
    <bundle_name>.app/Contents/MacOS/<executable>     the app; CFBundleExecutable
    <bundle_name>.app/Contents/MacOS/<extra...>       next to it, under their own names (Tauri's externalBin)
    <bundle_name>.app/Contents/Resources/icon.icns

and signs the bundle ad hoc, as a local build of an app that is not distributed.
"""

def _plist(entries):
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
    ]
    for key in sorted(entries):
        value = entries[key]
        lines.append("  <key>%s</key>" % key)
        if type(value) == "bool":
            lines.append("  <true/>" if value else "  <false/>")
        else:
            lines.append("  <string>%s</string>" % value)
    lines += ["</dict>", "</plist>", ""]
    return "\n".join(lines)

def _macos_app_impl(ctx):
    app = ctx.actions.declare_directory(ctx.attr.bundle_name + ".app")
    plist = ctx.actions.declare_file(ctx.label.name + ".Info.plist")
    executable = ctx.executable.executable
    ctx.actions.write(plist, _plist({
        "CFBundleDevelopmentRegion": "English",
        "CFBundleDisplayName": ctx.attr.bundle_name,
        "CFBundleExecutable": executable.basename,
        "CFBundleIconFile": "icon.icns",
        "CFBundleIdentifier": ctx.attr.bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": ctx.attr.bundle_name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": ctx.attr.version,
        "CFBundleVersion": ctx.attr.version,
        "CSResourcesFileMapped": True,
        "LSMinimumSystemVersion": ctx.attr.minimum_os_version,
        "LSRequiresCarbon": True,
        "NSHighResolutionCapable": True,
    }))

    extras = ctx.files.extra_executables
    args = ctx.actions.args()
    args.add(app.path)
    args.add(plist)
    args.add(ctx.file.icon)
    args.add(executable)
    args.add_all(extras)
    ctx.actions.run_shell(
        outputs = [app],
        inputs = [plist, ctx.file.icon, executable] + extras,
        arguments = [args],
        command = """
set -eu
app=$1 plist=$2 icon=$3; shift 3
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$plist" "$app/Contents/Info.plist"
cp "$icon" "$app/Contents/Resources/icon.icns"
for exe in "$@"; do
  cp "$exe" "$app/Contents/MacOS/"
done
chmod 755 "$app"/Contents/MacOS/*
/usr/bin/codesign --force --sign - "$app"
""",
        mnemonic = "MacosApp",
        progress_message = "Assembling %{output}",
        # codesign is the system's; the bundle is put together on this Mac.
        execution_requirements = {"no-remote": "1"},
    )
    return [DefaultInfo(files = depset([app]))]

macos_app = rule(
    implementation = _macos_app_impl,
    doc = "A macOS .app bundle around an executable, laid out as `tauri build` lays out this app.",
    attrs = {
        "bundle_id": attr.string(mandatory = True),
        "bundle_name": attr.string(mandatory = True, doc = "The app's name, and the bundle's directory name without .app."),
        "executable": attr.label(mandatory = True, executable = True, cfg = "target", doc = "The app's main executable."),
        "extra_executables": attr.label_list(allow_files = True, cfg = "target", doc = "Executables placed next to the main one, under their own names."),
        "icon": attr.label(mandatory = True, allow_single_file = [".icns"]),
        "minimum_os_version": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
    },
)
