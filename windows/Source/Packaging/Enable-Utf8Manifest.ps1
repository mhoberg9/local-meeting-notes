param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Xml;
public static class PortableManifestFix {
    private delegate bool LangCallback(IntPtr module, IntPtr type, IntPtr name, ushort language, IntPtr parameter);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool EnumResourceLanguagesW(IntPtr module, IntPtr type, IntPtr name, LangCallback callback, IntPtr parameter);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr FindResourceExW(IntPtr module, IntPtr type, IntPtr name, ushort language);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr BeginUpdateResourceW(string path, bool delete);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool UpdateResourceW(IntPtr update, IntPtr type, IntPtr name, ushort language, byte[] bytes, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool EndUpdateResourceW(IntPtr update, bool discard);
    public static void Patch(string path) {
        var languages = new List<ushort>();
        var changed = new List<byte[]>();
        IntPtr module = LoadLibraryExW(path, IntPtr.Zero, 2);
        if (module == IntPtr.Zero) throw new Win32Exception();
        try {
            LangCallback callback = (m,t,n,l,p) => { languages.Add(l); return true; };
            if (!EnumResourceLanguagesW(module, (IntPtr)24, (IntPtr)1, callback, IntPtr.Zero)) throw new Win32Exception();
            foreach (ushort language in languages) {
                IntPtr resource = FindResourceExW(module, (IntPtr)24, (IntPtr)1, language);
                byte[] bytes = new byte[SizeofResource(module, resource)];
                Marshal.Copy(LockResource(LoadResource(module, resource)), bytes, 0, bytes.Length);
                var xml = new XmlDocument();
                xml.LoadXml(Encoding.UTF8.GetString(bytes).Trim('\uFEFF','\0'));
                const string v3 = "urn:schemas-microsoft-com:asm.v3";
                XmlElement application = (XmlElement)xml.SelectSingleNode("/*/*[local-name()='application' and namespace-uri()='"+v3+"']");
                if (application == null) { application = xml.CreateElement("application",v3); xml.DocumentElement.AppendChild(application); }
                XmlElement settings = (XmlElement)application.SelectSingleNode("*[local-name()='windowsSettings']");
                if (settings == null) { settings = xml.CreateElement("windowsSettings",v3); application.AppendChild(settings); }
                foreach (var pair in new[] { new[] { "activeCodePage", "http://schemas.microsoft.com/SMI/2019/WindowsSettings", "UTF-8" }, new[] { "longPathAware", "http://schemas.microsoft.com/SMI/2016/WindowsSettings", "true" } }) {
                    XmlElement node = (XmlElement)settings.SelectSingleNode("*[local-name()='"+pair[0]+"']");
                    if (node == null) { node = xml.CreateElement(pair[0],pair[1]); settings.AppendChild(node); }
                    node.InnerText = pair[2];
                }
                changed.Add(new UTF8Encoding(false).GetBytes(xml.OuterXml));
            }
        } finally { FreeLibrary(module); }
        IntPtr update = BeginUpdateResourceW(path, false);
        if (update == IntPtr.Zero) throw new Win32Exception();
        bool discard = true;
        try {
            for (int i=0;i<languages.Count;i++) if (!UpdateResourceW(update,(IntPtr)24,(IntPtr)1,languages[i],changed[i],(uint)changed[i].Length)) throw new Win32Exception();
            discard = false;
        } finally { if (!EndUpdateResourceW(update,discard) && !discard) throw new Win32Exception(); }
    }
}
"@
[PortableManifestFix]::Patch((Resolve-Path -LiteralPath $Path).Path)

