"""Observe real Simulator display configuration changes, without simulating view bounds."""
import json, os, pathlib, plistlib, re, subprocess, sys, time

OUT=pathlib.Path('build/system-displays');OUT.mkdir(parents=True,exist_ok=True)
def command(*args,timeout=60,check=True):
    print('Running:',args,flush=True)
    try:result=subprocess.run(args,text=True,capture_output=True,timeout=timeout)
    except subprocess.TimeoutExpired as error:
        def text(value):return value.decode(errors='replace') if isinstance(value,bytes) else value or ''
        result=subprocess.CompletedProcess(args,124,text(error.stdout),text(error.stderr)+f'\nTimed out after {timeout}s')
    with (OUT/'commands.log').open('a') as log:log.write(repr(args)+'\n'+result.stdout+result.stderr+'\n')
    if check and result.returncode:raise RuntimeError(str(args)+'\n'+result.stdout+result.stderr)
    return result
def write(path,value):
    temp=path.with_suffix('.tmp');temp.write_text(json.dumps(value,indent=2));temp.replace(path)

sdk=command('xcrun','--sdk','iphonesimulator','--show-sdk-path').stdout.strip()
sdk_version=command('xcrun','--sdk','iphonesimulator','--show-sdk-version').stdout.strip()
app=OUT/'SystemDisplay.app';app.mkdir(exist_ok=True)
command('xcrun','--sdk','iphonesimulator','clang','-target','arm64-apple-ios18.5-simulator','-isysroot',sdk,'-fobjc-arc','-fmodules','App/SystemDisplayFixture.m','-framework','UIKit','-framework','Foundation','-framework','QuartzCore','-framework','Metal','-o',str(app/'SystemDisplay'))
bundle='local.astaps.SystemDisplayFixture'
info={'CFBundleExecutable':'SystemDisplay','CFBundleIdentifier':bundle,'CFBundleName':'SystemDisplay','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1','CFBundleVersion':'1','MinimumOSVersion':'18.5','UIDeviceFamily':[1,2],'LSRequiresIPhoneOS':True,'UIRequiresFullScreen':False,'UILaunchScreen':{},'UIStatusBarHidden':True,'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationPortraitUpsideDown','UIInterfaceOrientationLandscapeRight','UIInterfaceOrientationLandscapeLeft'],'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneClassName':'UIWindowScene','UISceneConfigurationName':'SystemDisplay','UISceneDelegateClassName':'RPSystemScene'}]}}}
(app/'Info.plist').write_bytes(plistlib.dumps(info));command('codesign','--force','--sign','-',str(app))
inventory=json.loads(command('xcrun','simctl','list','devices','available','--json').stdout)
def normalized_version(value):
    parts=tuple(map(int,re.split(r'[-.]',value)))
    return (parts+(0,0,0))[:3]
def version(runtime):return normalized_version(re.search(r'\.iOS-(\d+(?:-\d+)*)',runtime).group(1))
available=[dict(d,runtime=r) for r,ds in inventory['devices'].items() if '.iOS-' in r and version(r)<=normalized_version(sdk_version) for d in ds if d['name']=='iPhone Duo']
assert available,'No SDK-compatible Duo Simulator'
device=max(available,key=lambda d:version(d['runtime']))
types=json.loads(command('xcrun','simctl','list','devicetypes','--json').stdout)['devicetypes']
kind=next(t['identifier'] for t in types if t['name']=='iPhone Duo')
udid=command('xcrun','simctl','create','DisplayMigration-'+str(os.getpid()),kind,device['runtime']).stdout.strip()
assert re.fullmatch(r'[A-Fa-f0-9-]{36}',udid)
result={'actualGameRendererTested':False,'physicalHingeTested':False,'syntheticViewBounds':False,'observations':[],'sdk':sdk_version,'runtime':device['runtime']}
try:
    command('xcrun','simctl','boot',udid);command('xcrun','simctl','bootstatus',udid,'-b',timeout=240)
    (OUT/'initial-ports.txt').write_text(command('xcrun','simctl','io',udid,'enumerate').stdout)
    command('xcrun','simctl','install',udid,str(app),timeout=150)
    doc=pathlib.Path(command('xcrun','simctl','get_app_container',udid,bundle,'data').stdout.strip())/'Documents'
    command('xcrun','simctl','launch',udid,bundle)
    state_path=doc/'system-display-state.json';request_path=doc/'system-display-request.json'
    start=time.monotonic()
    while not state_path.is_file() and time.monotonic()-start<20:time.sleep(.25)
    initial=json.loads(state_path.read_text());launch_id=initial['launchID'];sequence=0
    def observe(name,orientation=None):
        global sequence
        sequence+=1;request={'sequence':sequence}
        if orientation:request['orientation']=orientation
        expected_orientation={2:1,4:2,8:3,16:4}.get(orientation)
        write(request_path,request);start=time.monotonic();state={}
        while time.monotonic()-start<12:
            try:state=json.loads(state_path.read_text())
            except (ValueError,FileNotFoundError):time.sleep(.2);continue
            geometry_ready=not expected_orientation or state.get('orientation')==expected_orientation or state.get('geometryError')
            if state.get('lastFrameSequence')==sequence and state.get('readbackValid') and time.time()-state['at']<2 and geometry_ready:break
            time.sleep(.2)
        row={'name':name,'sequence':sequence,'state':state,'freshFrame':state.get('lastFrameSequence')==sequence and state.get('readbackValid') and time.time()-state.get('at',0)<2,'sameProcess':state.get('launchID')==launch_id,'captures':[],
            'orientationRequested':expected_orientation,'orientationReached':not expected_orientation or state.get('orientation')==expected_orientation}
        result['observations'].append(row);write(OUT/'result.json',result)
        if row['freshFrame']:
            time.sleep(.4)
            # IDs 1 and 3 are the two ports exposed in the preceding Duo run.
            # Record failures; never assume either is the active screen.
            for display in ('1','3'):
                shot=OUT/f'{sequence}-{display}.png'
                capture=command('xcrun','simctl','io',udid,'screenshot','--display='+display,str(shot),check=False,timeout=35)
                if capture.returncode==0:
                    checked=command(sys.executable,'scripts/check_display_frame.py',str(shot),str(state['red']),str(state['green']),check=False)
                    row['captures'].append(dict(display=display,**json.loads(checked.stdout)))
                else:row['captures'].append({'display':display,'passed':False,'error':capture.stderr[-500:]})
            row['compositorConfirmed']=any(c['passed'] for c in row['captures'])
        else:row['compositorConfirmed']=False
        row['passed']=row['freshFrame'] and row['sameProcess'] and row['compositorConfirmed'] and row['orientationReached']
        try:row['afterCaptureState']=json.loads(state_path.read_text())
        except (ValueError,FileNotFoundError) as error:row['afterCaptureError']=str(error)
        write(OUT/'result.json',result)
        print(json.dumps({k:v for k,v in row.items() if k not in ('state','captures')}),flush=True)
    observe('initial')
    for repeat in range(2):
        for active in ('1','3'):
            other='3' if active=='1' else '1'
            on=command('xcrun','simctl','io',udid,'screenConfig','--display='+active,'power','on',check=False)
            off=command('xcrun','simctl','io',udid,'screenConfig','--display='+other,'power','off',check=False)
            result.setdefault('powerCommands',[]).append({'repeat':repeat,'active':active,'on':on.returncode,'off':off.returncode})
            time.sleep(1);observe(f'power-{active}-only-{repeat}')
    for display in ('1','3'):command('xcrun','simctl','io',udid,'screenConfig','--display='+display,'power','on',check=False)
    observe('both-screens-restored')
    for mask in (8,16,2,4,8):observe('orientation-'+str(mask),mask)
    states=[row['state'] for row in result['observations'] if row['freshFrame']]
    result.update(infrastructureCompleted=True,allObservedFramesPassed=all(row['passed'] for row in result['observations']),
        sceneScreenIdentities=sorted({s['screen'] for s in states}),windowSizes=sorted({tuple(s['window']) for s in states}),
        systemDisplayMigrationObserved=len({s['screen'] for s in states})>1,
        physicalAcceptance=False)
    (OUT/'final-ports.txt').write_text(command('xcrun','simctl','io',udid,'enumerate').stdout)
finally:
    write(OUT/'result.json',result)
    command('xcrun','simctl','shutdown',udid,check=False,timeout=30)
print(json.dumps({k:v for k,v in result.items() if k!='observations'},indent=2))
