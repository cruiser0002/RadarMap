import os
import sys

def create_pbxproj():
    project_dir = os.path.dirname(os.path.abspath(__file__))
    radarmap_dir = os.path.join(project_dir, "RadarMap")
    companion_dir = os.path.join(project_dir, "RadarMapCompanion")
    xcodeproj_dir = os.path.join(project_dir, "RadarMap.xcodeproj")
    os.makedirs(xcodeproj_dir, exist_ok=True)
    
    # Watch Swift files
    watch_swift_files = []
    for root, _, files in os.walk(radarmap_dir):
        for f in files:
            if f.endswith(".swift"):
                rel_path = os.path.relpath(os.path.join(root, f), radarmap_dir)
                watch_swift_files.append((f, rel_path))
                
    # iOS Companion Swift files
    ios_swift_files = [("RadarMapCompanionApp.swift", "RadarMapCompanionApp.swift")]
    
    file_refs = []
    build_files = []
    
    # IDs
    watch_app_ref_id = "1A0000010000000000000001"
    ios_app_ref_id = "2A0000010000000000000001"
    
    file_refs.append(f'\t\t{watch_app_ref_id} /* RadarMap Watch App.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "RadarMap Watch App.app"; sourceTree = BUILT_PRODUCTS_DIR; }};')
    file_refs.append(f'\t\t{ios_app_ref_id} /* RadarMap.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "RadarMap.app"; sourceTree = BUILT_PRODUCTS_DIR; }};')
    
    # Watch files
    watch_file_ids = {}
    watch_build_ids = {}
    ios_watch_build_ids = {}
    idx = 100
    for fname, rel_path in watch_swift_files:
        f_id = f"FF{idx:06d}0000000000000001"
        b_id = f"FF{idx:06d}0000000000000002"
        watch_file_ids[fname] = f_id
        watch_build_ids[fname] = b_id
        file_refs.append(f'\t\t{f_id} /* {fname} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{rel_path}"; sourceTree = "<group>"; }};')
        build_files.append(f'\t\t{b_id} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {f_id} /* {fname} */; }};')
        if fname != "RadarMapApp.swift":
            ios_b_id = f"2F{idx:06d}0000000000000002"
            ios_watch_build_ids[fname] = ios_b_id
            build_files.append(f'\t\t{ios_b_id} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {f_id} /* {fname} */; }};')
        idx += 1
        
    watch_info_plist_id = "FF0000010000000000000001"
    file_refs.append(f'\t\t{watch_info_plist_id} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/Info.plist"; sourceTree = "<group>"; }};')
    
    google_plist_id = "FF0000020000000000000001"
    google_plist_build_id = "FF0000020000000000000002"
    ios_google_plist_id = "2F0000020000000000000003"
    ios_google_plist_build_id = "2F0000020000000000000002"
    file_refs.append(f'\t\t{google_plist_id} /* GoogleService-Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/GoogleService-Info.plist"; sourceTree = "<group>"; }};')
    file_refs.append(f'\t\t{ios_google_plist_id} /* GoogleService-Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "../RadarMap/Resources/GoogleService-Info.plist"; sourceTree = "<group>"; }};')
    build_files.append(f'\t\t{google_plist_build_id} /* GoogleService-Info.plist in Resources */ = {{isa = PBXBuildFile; fileRef = {google_plist_id} /* GoogleService-Info.plist */; }};')
    build_files.append(f'\t\t{ios_google_plist_build_id} /* GoogleService-Info.plist in Resources */ = {{isa = PBXBuildFile; fileRef = {ios_google_plist_id} /* GoogleService-Info.plist */; }};')

    assets_id = "FF0000030000000000000001"
    assets_build_id = "FF0000030000000000000002"
    file_refs.append(f'\t\t{assets_id} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "Resources/Assets.xcassets"; sourceTree = "<group>"; }};')
    build_files.append(f'\t\t{assets_build_id} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_id} /* Assets.xcassets */; }};')
    
    ios_assets_build_id = "2F0000030000000000000002"
    build_files.append(f'\t\t{ios_assets_build_id} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_id} /* Assets.xcassets */; }};')

    watch_entitlements_id = "FF0000040000000000000001"
    file_refs.append(f'\t\t{watch_entitlements_id} /* RadarMapWatch.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = "Resources/RadarMapWatch.entitlements"; sourceTree = "<group>"; }};')

    # iOS Companion files
    ios_swift_id = "2F0001000000000000000001"
    ios_swift_build_id = "2F0001000000000000000002"
    file_refs.append(f'\t\t{ios_swift_id} /* RadarMapCompanionApp.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "RadarMapCompanionApp.swift"; sourceTree = "<group>"; }};')
    build_files.append(f'\t\t{ios_swift_build_id} /* RadarMapCompanionApp.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {ios_swift_id} /* RadarMapCompanionApp.swift */; }};')
    
    ios_info_plist_id = "2F0000010000000000000001"
    file_refs.append(f'\t\t{ios_info_plist_id} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/Info.plist"; sourceTree = "<group>"; }};')

    ios_entitlements_id = "2F0000020000000000000001"
    file_refs.append(f'\t\t{ios_entitlements_id} /* RadarMapCompanion.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = "Resources/RadarMapCompanion.entitlements"; sourceTree = "<group>"; }};')
    
    # Embed watch app build file
    embed_watch_build_id = "2A0000020000000000000001"
    build_files.append(f'\t\t{embed_watch_build_id} /* RadarMap Watch App.app in Embed Watch Content */ = {{isa = PBXBuildFile; fileRef = {watch_app_ref_id} /* RadarMap Watch App.app */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};')

    watch_group_children = [f'\t\t\t\t{watch_file_ids[fname]} /* {fname} */,' for fname, _ in watch_swift_files]
    watch_group_children.append(f'\t\t\t\t{watch_info_plist_id} /* Info.plist */,')
    watch_group_children.append(f'\t\t\t\t{google_plist_id} /* GoogleService-Info.plist */,')
    watch_group_children.append(f'\t\t\t\t{assets_id} /* Assets.xcassets */,')
    watch_group_children.append(f'\t\t\t\t{watch_entitlements_id} /* RadarMapWatch.entitlements */,')
    
    ios_group_children = [
        f'\t\t\t\t{ios_swift_id} /* RadarMapCompanionApp.swift */,',
        f'\t\t\t\t{ios_info_plist_id} /* Info.plist */,',
        f'\t\t\t\t{ios_entitlements_id} /* RadarMapCompanion.entitlements */,',
        f'\t\t\t\t{ios_google_plist_id} /* GoogleService-Info.plist */,',
    ]

    watch_sources_build_phase = [f'\t\t\t\t{watch_build_ids[fname]} /* {fname} in Sources */,' for fname, _ in watch_swift_files]
    watch_resources_build_phase = [
        f'\t\t\t\t{assets_build_id} /* Assets.xcassets in Resources */,',
        f'\t\t\t\t{google_plist_build_id} /* GoogleService-Info.plist in Resources */,',
    ]

    ios_sources_build_phase = [f'\t\t\t\t{ios_swift_build_id} /* RadarMapCompanionApp.swift in Sources */,']
    ios_resources_build_phase = [
        f'\t\t\t\t{ios_assets_build_id} /* Assets.xcassets in Resources */,',
        f'\t\t\t\t{ios_google_plist_build_id} /* GoogleService-Info.plist in Resources */,',
    ]
    for fname, _ in watch_swift_files:
        if fname != "RadarMapApp.swift":
            ios_sources_build_phase.append(f'\t\t\t\t{ios_watch_build_ids[fname]} /* {fname} in Sources */,')

    team_id = "2VUBR7QPFD"

    build_num_file = os.path.join(project_dir, "build_number.txt")
    if os.path.exists(build_num_file):
        with open(build_num_file, "r") as bf:
            build_num = bf.read().strip() or "1"
    else:
        build_num = "1"

    # Firebase (firebase-ios-sdk) Swift Package dependency.
    # Linked into both native targets: "RadarMap Watch App" (the watchOS app) and "RadarMap"
    # (despite the name, this is the iOS Companion app target — see PRODUCT_BUNDLE_IDENTIFIER
    # com.radarmap.watch / INFOPLIST_FILE RadarMapCompanion/... below). Both targets compile
    # nearly all of the same RadarMap/ source files (including FirebaseSyncManager.swift), so
    # both need FirebaseCore (for FirebaseApp.configure()) and FirebaseDatabase (for the
    # Realtime Database SDK). FirebaseDatabaseInternal explicitly links WatchKit for watchOS
    # in firebase-ios-sdk's own Package.swift, confirming watchOS support for this product.
    firebase_package_ref_id = "3A0000010000000000000001"
    watch_firebase_core_dep_id = "3A0000020000000000000001"
    watch_firebase_core_buildfile_id = "3A0000020000000000000002"
    watch_firebase_database_dep_id = "3A0000030000000000000001"
    watch_firebase_database_buildfile_id = "3A0000030000000000000002"
    ios_firebase_core_dep_id = "3A0000040000000000000001"
    ios_firebase_core_buildfile_id = "3A0000040000000000000002"
    ios_firebase_database_dep_id = "3A0000050000000000000001"
    ios_firebase_database_buildfile_id = "3A0000050000000000000002"

    # QRCode (dagronf/QRCode) Swift Package dependency, linked into both native targets same as
    # Firebase above. Used instead of raw CoreImage because CoreImage's QR generator filter isn't
    # resolvable on watchOS in this project's toolchain (verified directly — even a plain
    # `import CoreImage` fails to resolve for the watchOS target); QRCode ships its own
    # pure-Swift generator for watchOS instead of relying on Core Image there. See
    # RadarMap/Views/Room/QRCodeView.swift.
    qrcode_package_ref_id = "3A0000060000000000000001"
    watch_qrcode_dep_id = "3A0000070000000000000001"
    watch_qrcode_buildfile_id = "3A0000070000000000000002"
    ios_qrcode_dep_id = "3A0000080000000000000001"
    ios_qrcode_buildfile_id = "3A0000080000000000000002"

    build_files.append(f'\t\t{watch_firebase_core_buildfile_id} /* FirebaseCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {watch_firebase_core_dep_id} /* FirebaseCore */; }};')
    build_files.append(f'\t\t{watch_firebase_database_buildfile_id} /* FirebaseDatabase in Frameworks */ = {{isa = PBXBuildFile; productRef = {watch_firebase_database_dep_id} /* FirebaseDatabase */; }};')
    build_files.append(f'\t\t{ios_firebase_core_buildfile_id} /* FirebaseCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {ios_firebase_core_dep_id} /* FirebaseCore */; }};')
    build_files.append(f'\t\t{ios_firebase_database_buildfile_id} /* FirebaseDatabase in Frameworks */ = {{isa = PBXBuildFile; productRef = {ios_firebase_database_dep_id} /* FirebaseDatabase */; }};')
    build_files.append(f'\t\t{watch_qrcode_buildfile_id} /* QRCode in Frameworks */ = {{isa = PBXBuildFile; productRef = {watch_qrcode_dep_id} /* QRCode */; }};')
    build_files.append(f'\t\t{ios_qrcode_buildfile_id} /* QRCode in Frameworks */ = {{isa = PBXBuildFile; productRef = {ios_qrcode_dep_id} /* QRCode */; }};')

    watch_frameworks_files_block = chr(10).join([
        f'\t\t\t\t{watch_firebase_core_buildfile_id} /* FirebaseCore in Frameworks */,',
        f'\t\t\t\t{watch_firebase_database_buildfile_id} /* FirebaseDatabase in Frameworks */,',
        f'\t\t\t\t{watch_qrcode_buildfile_id} /* QRCode in Frameworks */,',
    ])
    ios_frameworks_files_block = chr(10).join([
        f'\t\t\t\t{ios_firebase_core_buildfile_id} /* FirebaseCore in Frameworks */,',
        f'\t\t\t\t{ios_firebase_database_buildfile_id} /* FirebaseDatabase in Frameworks */,',
        f'\t\t\t\t{ios_qrcode_buildfile_id} /* QRCode in Frameworks */,',
    ])
    watch_package_product_deps_block = chr(10).join([
        f'\t\t\t\t{watch_firebase_core_dep_id} /* FirebaseCore */,',
        f'\t\t\t\t{watch_firebase_database_dep_id} /* FirebaseDatabase */,',
        f'\t\t\t\t{watch_qrcode_dep_id} /* QRCode */,',
    ])
    ios_package_product_deps_block = chr(10).join([
        f'\t\t\t\t{ios_firebase_core_dep_id} /* FirebaseCore */,',
        f'\t\t\t\t{ios_firebase_database_dep_id} /* FirebaseDatabase */,',
        f'\t\t\t\t{ios_qrcode_dep_id} /* QRCode */,',
    ])
    package_reference_block = chr(10).join([
        f'\t\t\t\t{firebase_package_ref_id} /* XCRemoteSwiftPackageReference "firebase-ios-sdk" */,',
        f'\t\t\t\t{qrcode_package_ref_id} /* XCRemoteSwiftPackageReference "QRCode" */,',
    ])

    xcremote_swift_package_reference_section = f'''/* Begin XCRemoteSwiftPackageReference section */
\t\t{firebase_package_ref_id} /* XCRemoteSwiftPackageReference "firebase-ios-sdk" */ = {{
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = "https://github.com/firebase/firebase-ios-sdk";
\t\t\trequirement = {{
\t\t\t\tkind = upToNextMajorVersion;
\t\t\t\tminimumVersion = 12.0.0;
\t\t\t}};
\t\t}};
\t\t{qrcode_package_ref_id} /* XCRemoteSwiftPackageReference "QRCode" */ = {{
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = "https://github.com/dagronf/QRCode.git";
\t\t\trequirement = {{
\t\t\t\tkind = upToNextMajorVersion;
\t\t\t\tminimumVersion = 20.0.0;
\t\t\t}};
\t\t}};
/* End XCRemoteSwiftPackageReference section */'''

    xcswift_package_product_dependency_section = f'''/* Begin XCSwiftPackageProductDependency section */
\t\t{watch_firebase_core_dep_id} /* FirebaseCore */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {firebase_package_ref_id} /* XCRemoteSwiftPackageReference "firebase-ios-sdk" */;
\t\t\tproductName = FirebaseCore;
\t\t}};
\t\t{watch_firebase_database_dep_id} /* FirebaseDatabase */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {firebase_package_ref_id} /* XCRemoteSwiftPackageReference "firebase-ios-sdk" */;
\t\t\tproductName = FirebaseDatabase;
\t\t}};
\t\t{ios_firebase_core_dep_id} /* FirebaseCore */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {firebase_package_ref_id} /* XCRemoteSwiftPackageReference "firebase-ios-sdk" */;
\t\t\tproductName = FirebaseCore;
\t\t}};
\t\t{ios_firebase_database_dep_id} /* FirebaseDatabase */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {firebase_package_ref_id} /* XCRemoteSwiftPackageReference "firebase-ios-sdk" */;
\t\t\tproductName = FirebaseDatabase;
\t\t}};
\t\t{watch_qrcode_dep_id} /* QRCode */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {qrcode_package_ref_id} /* XCRemoteSwiftPackageReference "QRCode" */;
\t\t\tproductName = QRCode;
\t\t}};
\t\t{ios_qrcode_dep_id} /* QRCode */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tpackage = {qrcode_package_ref_id} /* XCRemoteSwiftPackageReference "QRCode" */;
\t\t\tproductName = QRCode;
\t\t}};
/* End XCSwiftPackageProductDependency section */'''

    pbxproj_content = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
\t\t2A0000030000000000000001 /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = 1A0000090000000000000001 /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = 1A0000060000000000000001;
\t\t\tremoteInfo = "RadarMap Watch App";
\t\t}};
/* End PBXContainerItemProxy section */

/* Begin PBXCopyFilesBuildPhase section */
\t\t2A0000040000000000000001 /* Embed Watch Content */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "$(CONTENTS_FOLDER_PATH)/Watch";
\t\t\tdstSubfolderSpec = 16;
\t\t\tfiles = (
\t\t\t\t{embed_watch_build_id} /* RadarMap Watch App.app in Embed Watch Content */,
\t\t\t);
\t\t\tname = "Embed Watch Content";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFileReference section */
{chr(10).join(file_refs)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
\t\t1A0000020000000000000001 /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{watch_frameworks_files_block}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t2A0000050000000000000001 /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{ios_frameworks_files_block}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t1A0000030000000000000001 = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t2A0000060000000000000001 /* RadarMapCompanion */,
\t\t\t\t1A0000040000000000000001 /* RadarMap */,
\t\t\t\t1A0000050000000000000001 /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t2A0000060000000000000001 /* RadarMapCompanion */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{chr(10).join(ios_group_children)}
\t\t\t);
\t\t\tpath = RadarMapCompanion;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t1A0000040000000000000001 /* RadarMap */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{chr(10).join(watch_group_children)}
\t\t\t);
\t\t\tpath = RadarMap;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t1A0000050000000000000001 /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t2A0000010000000000000001 /* RadarMap.app */,
\t\t\t\t1A0000010000000000000001 /* RadarMap Watch App.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t2A0000070000000000000001 /* RadarMap */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = 2A0000080000000000000001 /* Build configuration list for PBXNativeTarget "RadarMap" */;
\t\t\tbuildPhases = (
\t\t\t\t2A0000090000000000000001 /* Sources */,
\t\t\t\t2A0000050000000000000001 /* Frameworks */,
\t\t\t\t2A0000100000000000000001 /* Resources */,
\t\t\t\t2A0000040000000000000001 /* Embed Watch Content */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t2A00000A0000000000000001 /* PBXTargetDependency */,
\t\t\t);
\t\t\tname = "RadarMap";
\t\t\tpackageProductDependencies = (
{ios_package_product_deps_block}
\t\t\t);
\t\t\tproductName = "RadarMap";
\t\t\tproductReference = 2A0000010000000000000001 /* RadarMap.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
\t\t1A0000060000000000000001 /* RadarMap Watch App */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = 1A0000070000000000000001 /* Build configuration list for PBXNativeTarget "RadarMap Watch App" */;
\t\t\tbuildPhases = (
\t\t\t\t1A0000000000000000000001 /* Increment Build Number */,
\t\t\t\t1A0000080000000000000001 /* Sources */,
\t\t\t\t1A0000020000000000000001 /* Frameworks */,
\t\t\t\t1A0000100000000000000001 /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = "RadarMap Watch App";
\t\t\tpackageProductDependencies = (
{watch_package_product_deps_block}
\t\t\t);
\t\t\tproductName = "RadarMap Watch App";
\t\t\tproductReference = 1A0000010000000000000001 /* RadarMap Watch App.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t1A0000090000000000000001 /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t2A0000070000000000000001 = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t\tDevelopmentTeam = {team_id};
\t\t\t\t\t\tProvisioningStyle = Automatic;
\t\t\t\t\t}};
\t\t\t\t\t1A0000060000000000000001 = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t\tDevelopmentTeam = {team_id};
\t\t\t\t\t\tProvisioningStyle = Automatic;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = 1A00000A0000000000000001 /* Build configuration list for PBXProject "RadarMap" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = 1A0000030000000000000001;
\t\t\tpackageReferences = (
{package_reference_block}
\t\t\t);
\t\t\tproductRefGroup = 1A0000050000000000000001 /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t2A0000070000000000000001 /* RadarMap */,
\t\t\t\t1A0000060000000000000001 /* RadarMap Watch App */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t1A0000100000000000000001 /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(watch_resources_build_phase)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t2A0000100000000000000001 /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(ios_resources_build_phase)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXShellScriptBuildPhase section */
		1A0000000000000000000001 /* Increment Build Number */ = {{
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			buildActionMask = 2147483647;
			files = (
			);
			inputFileListPaths = (
			);
			inputPaths = (
			);
			name = "Increment Build Number";
			outputFileListPaths = (
			);
			outputPaths = (
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "bash \\"$SRCROOT/scripts/increment_build.sh\\"";
		}};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t2A0000090000000000000001 /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(ios_sources_build_phase)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t1A0000080000000000000001 /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(watch_sources_build_phase)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
\t\t2A00000A0000000000000001 /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = 1A0000060000000000000001 /* RadarMap Watch App */;
\t\t\ttargetProxy = 2A0000030000000000000001 /* PBXContainerItemProxy */;
\t\t}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
\t\t1A00000B0000000000000001 /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tDEVELOPMENT_TEAM = {team_id};
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t1A00000C0000000000000001 /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tDEVELOPMENT_TEAM = {team_id};
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t2A00000B0000000000000001 /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = RadarMapCompanion/Resources/RadarMapCompanion.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = {build_num};
\t\t\t\tDEVELOPMENT_TEAM = {team_id};
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = RadarMapCompanion/Resources/Info.plist;
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "Radar Map";
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.radarmap.watch;
\t\t\t\tPRODUCT_NAME = "RadarMap";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSUPPORTED_PLATFORMS = "iphonesimulator iphoneos";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t2A00000C0000000000000001 /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = RadarMapCompanion/Resources/RadarMapCompanion.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = {build_num};
\t\t\t\tDEVELOPMENT_TEAM = {team_id};
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = RadarMapCompanion/Resources/Info.plist;
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "Radar Map";
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.radarmap.watch;
\t\t\t\tPRODUCT_NAME = "RadarMap";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSUPPORTED_PLATFORMS = "iphonesimulator iphoneos";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t1A00000D0000000000000001 /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = RadarMap/Resources/RadarMapWatch.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = {build_num};
\t\t\t\tDEVELOPMENT_TEAM = {team_id};
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = RadarMap/Resources/Info.plist;
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "Radar Map";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.radarmap.watch.watchkitapp;
\t\t\t\tPRODUCT_NAME = "RadarMap Watch App";
\t\t\t\tSDKROOT = watchos;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSUPPORTED_PLATFORMS = "watchsimulator watchos";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tTARGETED_DEVICE_FAMILY = "4";
\t\t\t\tWATCHOS_DEPLOYMENT_TARGET = 10.0;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t1A00000E0000000000000001 /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = RadarMap/Resources/RadarMapWatch.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = {build_num};
\t\t\t\tDEVELOPMENT_TEAM = {team_id};
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = RadarMap/Resources/Info.plist;
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "Radar Map";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.radarmap.watch.watchkitapp;
\t\t\t\tPRODUCT_NAME = "RadarMap Watch App";
\t\t\t\tSDKROOT = watchos;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSUPPORTED_PLATFORMS = "watchsimulator watchos";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tTARGETED_DEVICE_FAMILY = "4";
\t\t\t\tWATCHOS_DEPLOYMENT_TARGET = 10.0;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t1A00000A0000000000000001 /* Build configuration list for PBXProject "RadarMap" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t1A00000B0000000000000001 /* Debug */,
\t\t\t\t1A00000C0000000000000001 /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t2A0000080000000000000001 /* Build configuration list for PBXNativeTarget "RadarMap" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t2A00000B0000000000000001 /* Debug */,
\t\t\t\t2A00000C0000000000000001 /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t1A0000070000000000000001 /* Build configuration list for PBXNativeTarget "RadarMap Watch App" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t1A00000D0000000000000001 /* Debug */,
\t\t\t\t1A00000E0000000000000001 /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */

{xcremote_swift_package_reference_section}

{xcswift_package_product_dependency_section}

\t}};
\trootObject = 1A0000090000000000000001 /* Project object */;
}}
"""

    pbxproj_path = os.path.join(xcodeproj_dir, "project.pbxproj")
    with open(pbxproj_path, "w") as f:
        f.write(pbxproj_content)
    print(f"Generated unified iOS + watchOS Xcode project: {pbxproj_path}")

if __name__ == "__main__":
    create_pbxproj()
