#!/usr/bin/env python3
"""Record the developer-inspected T008 source boundary. No runtime/PASS inference."""
from pathlib import Path
import csv,hashlib
ROOT=Path(__file__).resolve().parents[1]
entries=[
 ('ThemePathPolicy','IncomeClock/Infrastructure/Theme/ThemePackageValidation.swift','enum ThemePathPolicy {','enum ThemePackageSchemaValidator {','String normalization; fixed en_US_POSIX Locale; diagnostic','String -> normalized String/collision key, or typed diagnostic; no URL resolution/filesystem/UI'),
 ('ThemeTokenSafetyValidator','IncomeClock/Infrastructure/Theme/ThemePackageValidation.swift','enum ThemeTokenSafetyValidator {','func diagnostic(','private normalize/normalizeMetrics/normalizedAppearanceMetrics/colors/rebuild; ThemeContrast; ThemeButtonStyleResolver; ValidatedTheme.warmIslandFallback; typed token/metric/adjustment values','Manifest value -> normalized tokens/metrics/adjustments or diagnostic; caller owns subsequent file/install operations'),
 ('ThemePackageSchemaValidator','IncomeClock/Infrastructure/Theme/ThemePackageValidation.swift','enum ThemePackageSchemaValidator {','enum ThemeTokenSafetyValidator {','Foundation JSONSerialization/JSONDecoder; fixed key sets; rejectUnknown/containsRemoteReference; ThemePackageManifest','Data -> typed manifest; value decoding is distinct from reading Data from an external URL'),
 ('diagnostic','IncomeClock/Infrastructure/Theme/ThemePackageValidation.swift','func diagnostic(',None,'ThemeValidationDiagnostic.init/category value enum','Constructs a value; does not present alert/sheet or write a log'),
 ('validateCompatibility','IncomeClock/Infrastructure/Theme/ThemeRepository.swift','    private func validateCompatibility(','    private func ignoredOptionalCapabilities(','SemanticVersion init/compare; immutable repository currentAppVersion; BuiltinThemeID; allowsFallback local helper; capability/profile/appearance values; diagnostic','Manifest + configured currentAppVersion -> void/typed diagnostic. Not mathematically argument-only: reads fixed actor configuration. No UI or repository I/O in this function.'),
 ('SemanticVersion','IncomeClock/Application/ThemeImportModels.swift','struct SemanticVersion:', '// Legacy strings remain wire-compatible.','String splitting/Int parse and lexicographic integer comparison','Value parser/comparator; no Bundle/network/UI access'),
 ('Theme value/contrast/button closure','IncomeClock/Application/ThemeModels.swift',None,None,'ThemeColorTokens/ThemeMetricTokens/ValidatedTheme literal fallback; BuiltinThemeID; ThemeContrast.ratio/safeTextColor/private rgba/composite/luminance; ThemeButtonStyleResolver.resolve; role/state enums','Foundation-only model module; color values are hex strings/numbers, not NSColor/SwiftUI View. File URL is a source descriptor value, not an opened resource.')
]
rows=[]
for name,path,start,end,deps,boundary in entries:
 p=ROOT/path;s=p.read_text();a=s.index(start) if start else 0;b=s.index(end,a+len(start)) if end else len(s);part=s[a:b]
 rows.append(dict(requirement='T-008.a',node=name,path=path,start_line=s.count('\n',0,a)+1,end_line=s.count('\n',0,b)+1,source_sha256=hashlib.sha256(p.read_bytes()).hexdigest(),fragment_sha256=hashlib.sha256(part.encode()).hexdigest(),dependency_edges=deps,inspected_boundary=boundary,observation='DEVELOPER_SOURCE_SCOPE_ONLY',excluded_claim='No test pass or independent acceptance; no purity claim for entire ThemeRepository actor/validatePackage/install/media I/O',producer='python3 scripts/stage9_theme_validator_closure.py'))
with (ROOT/'STAGE9_CLOSEOUT_THEME_VALIDATOR_CLOSURE.tsv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=list(rows[0]),delimiter='\t',lineterminator='\n');w.writeheader();w.writerows(rows)
print(f'{len(rows)} source-boundary nodes recorded; runtime/PASS claims=0')
