import Foundation

public enum FlutterAPK {
  public static let packScript = """
    import os
    import sys
    import zipfile

    root, dest = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(dest, "w") as archive:
        for dirpath, _, names in os.walk(root):
            for name in names:
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, root)
                stored = rel.endswith(".so") or rel.endswith(".arsc") or rel == "AndroidManifest.xml"
                kind = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
                archive.write(path, rel, kind)
    """
}
