#!/usr/bin/env python3
"""Stage a complete matched Mac engine/library set without running an installer."""
from pathlib import Path
import subprocess, shutil, hashlib, json, argparse
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--source',choices=('school','sequoia'),default='sequoia')
parser.add_argument('--source-path',type=Path,help='Location of a separately obtained upstream client')
parser.add_argument('--output',type=Path,help='Where to stage the local engine')
args=parser.parse_args()
if args.source=='sequoia':
    source=args.source_path or root/'research/sequoia'
    client=source/'iNodeClient';libraries=source/'lib';custom=source/'custom'
    commit=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
else:
    source=args.source_path or root/'research/mac-original/payload'
    client=source/'Applications/iNodeClient';libraries=source/'usr/local/lib';custom=client/'custom'
    commit=None
version=next(line.split('=',1)[1].strip() for line in (client/'resource/inode_en.txt').read_text(encoding='latin-1').splitlines() if line.startswith('MAC_LINUX_VERSION_DETAIL_SHOW='))
target=args.output or root/'.build/vendor-mac'
if target.exists(): shutil.rmtree(target)
target.mkdir(parents=True)
shutil.copy2(client/'AuthenMngService',target/'AuthenMngService')
shutil.copytree(client/'conf',target/'conf')
shutil.copytree(custom,target/'custom')
shutil.copytree(client/'resource',target/'resource')
for folder in ('log','ipc-node','clientfiles/8021','clientfiles/5020','clientfiles/7000'):
    (target/folder).mkdir(parents=True,exist_ok=True)
(target/'conf/iNode.conf').write_text('LOG_LEVEL=0\nFORBID_PAP=0\n')
shutil.copytree(libraries,target/'lib',symlinks=True)
manifest={}
for p in target.rglob('*'):
    if not p.is_file() or p.is_symlink(): continue
    manifest[str(p.relative_to(target))]=hashlib.sha256(p.read_bytes()).hexdigest()
    if p.read_bytes()[:4] not in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe'): continue
    dependencies=subprocess.check_output(['/usr/bin/otool','-L',str(p)],text=True).splitlines()[1:]
    for line in dependencies:
        old=line.strip().split(' (compatibility')[0]
        name=Path(old).name
        if not (target/'lib'/name).exists(): continue
        # Some E0585 libraries have no header padding for longer load commands.
        # Basenames resolve through the engine's private DYLD_LIBRARY_PATH.
        new=name if p.parent==target/'lib' else '@executable_path/lib/'+name
        subprocess.run(['/usr/bin/install_name_tool','-change',old,new,str(p)],check=True,capture_output=True)
    content=p.read_bytes().replace(b"/tmp/iNode/",b"./ipc-node/")
    old=b'/etc/iNode/inodesys.conf\0'
    if old in content:
        new=b'./inodesys.conf\0';content=content.replace(old,new+b'\0'*(len(old)-len(new)))
    p.write_bytes(content)
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(p)],check=True,capture_output=True)
(target/'inodesys.conf').write_text('INSTALL_DIR='+str(target)+'\n')
if args.output is None:
    manifest_path=root/'.build/vendor-source-manifest.json'
    manifest_path.parent.mkdir(parents=True,exist_ok=True)
    manifest_path.write_text(json.dumps(manifest,indent=2))
profile=1 if args.source=='sequoia' else 0
metadata={'source':args.source,'version':version,'commit':commit,'ipc_profile':profile,'original_sha256':manifest}
(target/'ipc-profile.txt').write_text(f'{profile}\n')
(target/'engine-info.txt').write_text(f'{args.source}: {version}\n')
(target/'source.json').write_text(json.dumps(metadata,indent=2))
print(f'{target}: {args.source}, {version}')
