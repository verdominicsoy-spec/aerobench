"""STEP files built in tests, with named parts."""

from __future__ import annotations

from OCP.gp import gp_Trsf


def write_parts(path, parts: dict, placements: dict | None = None):
    """A STEP file with one named part per shape; `placements` maps a part
    name to a list of gp_Vec offsets to place it several times."""
    from OCP.IFSelect import IFSelect_RetDone
    from OCP.STEPCAFControl import STEPCAFControl_Writer
    from OCP.STEPControl import STEPControl_AsIs
    from OCP.TCollection import TCollection_ExtendedString
    from OCP.TDataStd import TDataStd_Name
    from OCP.TDocStd import TDocStd_Document
    from OCP.TopLoc import TopLoc_Location
    from OCP.XCAFDoc import XCAFDoc_DocumentTool

    doc = TDocStd_Document(TCollection_ExtendedString("XmlOcaf"))
    tool = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    name = lambda label, text: TDataStd_Name.Set_s(label, TCollection_ExtendedString(text))
    if placements:
        assy = tool.NewShape()
        name(assy, "Assembly")
    for text, shape in parts.items():
        label = tool.AddShape(shape, False)
        name(label, text)
        for k, v in enumerate((placements or {}).get(text, [])):
            t = gp_Trsf()
            t.SetTranslation(v)
            c = tool.AddComponent(assy, label, TopLoc_Location(t))
            name(c, f"{text} {k + 1}")
    tool.UpdateAssemblies()
    w = STEPCAFControl_Writer()
    w.SetNameMode(True)
    w.Transfer(doc, STEPControl_AsIs)
    assert w.Write(str(path)) == IFSelect_RetDone
    return path
