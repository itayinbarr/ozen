// Fills Ozen's App Store listing from ios/release/metadata/*.json and uploads screenshots
// from ios/AppStore/screenshots/<locale>/. Idempotent: re-running updates in place.
// Never submits for review — that stays a manual, deliberate step.
//
//   node ios/release/asc-metadata.mjs [--version 1.0.0] [--no-screenshots] [--dry-run]
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { api, appByBundle } from './asc-client.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const VERSION = args.includes('--version') ? args[args.indexOf('--version') + 1] : '1.0.0';
const DRY = args.includes('--dry-run');
const SHOTS = !args.includes('--no-screenshots');
const BUNDLE = 'com.itayinbar.ozen';
const LOCALES = { he: 'he', 'en-US': 'en-US' };

const app = await appByBundle(BUNDLE);
if (!app) throw new Error(`Create the app record for ${BUNDLE} in App Store Connect first (ios/release/README.md).`);
console.log(`App ${app.attributes.name} (${app.id}), primary locale ${app.attributes.primaryLocale}`);
const meta = Object.fromEntries(Object.keys(LOCALES).map((l) => [l, JSON.parse(readFileSync(join(HERE, 'metadata', `${l}.json`), 'utf8'))]));

async function upsert(listPath, type, parentRel, parentId, locale, attrs) {
  const existing = (await api('GET', listPath)).data.find((x) => x.attributes.locale === locale);
  if (DRY) return console.log(`  [dry] ${type} ${locale}`, Object.keys(attrs).join(','));
  if (existing) {
    await api('PATCH', `/v1/${type}/${existing.id}`, { data: { type, id: existing.id, attributes: attrs } });
    return existing.id;
  }
  const created = await api('POST', `/v1/${type}`, { data: { type, attributes: { locale, ...attrs },
    relationships: { [parentRel]: { data: { type: parentRel === 'appInfo' ? 'appInfos' : 'appStoreVersions', id: parentId } } } } });
  return created.data.id;
}

// ---- App info: name, subtitle, privacy URL, categories
const appInfo = (await api('GET', `/v1/apps/${app.id}/appInfos`)).data
  .find((i) => !['READY_FOR_DISTRIBUTION', 'REPLACED_WITH_NEW_INFO'].includes(i.attributes.appStoreState ?? i.attributes.state)) ?? (await api('GET', `/v1/apps/${app.id}/appInfos`)).data[0];
for (const [l, m] of Object.entries(meta)) {
  await upsert(`/v1/appInfos/${appInfo.id}/appInfoLocalizations`, 'appInfoLocalizations', 'appInfo', appInfo.id, LOCALES[l],
    { name: m.name, subtitle: m.subtitle, privacyPolicyUrl: m.privacyPolicyUrl });
  console.log(`✓ app info ${l}`);
}
if (!DRY) {
  await api('PATCH', `/v1/appInfos/${appInfo.id}`, { data: { type: 'appInfos', id: appInfo.id, relationships: {
    primaryCategory: { data: { type: 'appCategories', id: 'PRODUCTIVITY' } },
    secondaryCategory: { data: { type: 'appCategories', id: 'UTILITIES' } } } } });
  console.log('✓ categories Productivity / Utilities');
}

// ---- Age rating: nothing objectionable → 4+
try {
  const decl = (await api('GET', `/v1/appInfos/${appInfo.id}/ageRatingDeclaration`)).data;
  const none = ['alcoholTobaccoOrDrugUseOrReferences', 'contests', 'gamblingSimulated', 'horrorOrFearThemes', 'matureOrSuggestiveThemes',
    'medicalOrTreatmentInformation', 'profanityOrCrudeHumor', 'sexualContentGraphicAndNudity', 'sexualContentOrNudity',
    'violenceCartoonOrFantasy', 'violenceRealistic', 'violenceRealisticProlongedGraphicOrSadistic'];
  const attrs = Object.fromEntries(none.map((k) => [k, 'NONE']));
  Object.assign(attrs, { gambling: false, unrestrictedWebAccess: false, lootBox: false, messagingAndChat: false,
    userGeneratedContent: false, parentalControls: false, ageAssurance: false, advertising: false, healthOrWellnessTopics: false });
  if (!DRY) await patchTolerant('ageRatingDeclarations', decl.id, attrs);
  console.log('✓ age rating 4+');
} catch (e) { console.log(`! age rating: ${e.message} — set it in App Store Connect`); }

// PATCH, dropping any attribute this API version doesn't know, one at a time.
async function patchTolerant(type, id, attrs) {
  const a = { ...attrs };
  for (let i = 0; i < 20; i += 1) {
    try { return await api('PATCH', `/v1/${type}/${id}`, { data: { type, id, attributes: a } }); }
    catch (e) {
      const bad = Object.keys(a).find((k) => e.message.includes(`'${k}'`) || e.message.includes(`/${k}`) || e.message.includes(` ${k} `));
      if (!bad) throw e;
      delete a[bad];
    }
  }
}

// ---- Price: free
try {
  const sched = await api('GET', `/v1/apps/${app.id}/appPriceSchedule`).catch(() => null);
  if (!sched?.data && !DRY) {
    const free = (await api('GET', `/v1/apps/${app.id}/appPricePoints?filter[territory]=USA&limit=200`)).data
      .find((p) => Number(p.attributes.customerPrice) === 0);
    await api('POST', '/v1/appPriceSchedules', { data: { type: 'appPriceSchedules', relationships: {
      app: { data: { type: 'apps', id: app.id } },
      baseTerritory: { data: { type: 'territories', id: 'USA' } },
      manualPrices: { data: [{ type: 'appPrices', id: '${price1}' }] } } },
      included: [{ type: 'appPrices', id: '${price1}', attributes: { startDate: null },
        relationships: { appPricePoint: { data: { type: 'appPricePoints', id: free.id } } } }] });
  }
  console.log('✓ price free');
} catch (e) { console.log(`! price: ${e.message} — set "Free" in App Store Connect → Pricing`); }

// ---- Version + localizations
let version = (await api('GET', `/v1/apps/${app.id}/appStoreVersions?filter[platform]=IOS&limit=10`)).data
  .find((v) => ['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED'].includes(v.attributes.appStoreState ?? v.attributes.appVersionState));
if (!version && !DRY) {
  version = (await api('POST', '/v1/appStoreVersions', { data: { type: 'appStoreVersions', attributes: { platform: 'IOS', versionString: VERSION },
    relationships: { app: { data: { type: 'apps', id: app.id } } } } })).data;
}
if (version && version.attributes.versionString !== VERSION && !DRY) {
  await api('PATCH', `/v1/appStoreVersions/${version.id}`, { data: { type: 'appStoreVersions', id: version.id, attributes: { versionString: VERSION } } });
}
if (version && !DRY) {
  await api('PATCH', `/v1/appStoreVersions/${version.id}`, { data: { type: 'appStoreVersions', id: version.id,
    attributes: { copyright: `${new Date().getFullYear()} Itay Inbar`, releaseType: 'MANUAL' } } });
}
console.log(`✓ version ${VERSION}${version ? ` (${version.id})` : ''}`);

const versionLocIds = {};
for (const [l, m] of Object.entries(meta)) {
  if (!version) break;
  const attrs = { description: m.description, keywords: m.keywords, promotionalText: m.promotionalText, supportUrl: m.supportUrl, marketingUrl: m.marketingUrl };
  versionLocIds[l] = await upsert(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`, 'appStoreVersionLocalizations',
    'appStoreVersion', version.id, LOCALES[l], attrs);
  console.log(`✓ version text ${l}`);
}

// ---- Review details
if (version && !DRY) {
  const notes = 'Ozen transcribes Hebrew speech fully on-device (no network, no account). To test: tap the orange orb, speak Hebrew (or play a Hebrew video), '
    + 'tap again to stop; or use the upload button to import an audio file. Recording continues with the screen locked and can be paused/stopped from the Live Activity.';
  const existing = await api('GET', `/v1/appStoreVersions/${version.id}/appStoreReviewDetail`).catch(() => null);
  const attrs = { contactFirstName: 'Itay', contactLastName: 'Inbar', contactEmail: 'itayinbar.me@gmail.com', contactPhone: process.env.OZEN_REVIEW_PHONE || '',
    demoAccountRequired: false, notes };
  if (!attrs.contactPhone) delete attrs.contactPhone;
  if (existing?.data) await api('PATCH', `/v1/appStoreReviewDetails/${existing.data.id}`, { data: { type: 'appStoreReviewDetails', id: existing.data.id, attributes: attrs } });
  else await api('POST', '/v1/appStoreReviewDetails', { data: { type: 'appStoreReviewDetails', attributes: attrs,
    relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } } } });
  console.log(`✓ review details${attrs.contactPhone ? '' : ' (no phone — set OZEN_REVIEW_PHONE or add it in App Store Connect)'}`);
}

// ---- Screenshots
if (SHOTS && version && !DRY) {
  for (const l of Object.keys(meta)) {
    const dir = join(HERE, '..', 'AppStore', 'screenshots', l === 'en-US' ? 'en' : l);
    const fallback = join(HERE, '..', 'AppStore', 'screenshots', 'he');
    const src = existsSync(dir) ? dir : fallback;
    if (!existsSync(src)) { console.log(`! no screenshots in ${dir}`); continue; }
    const files = readdirSync(src).filter((f) => f.endsWith('.png')).sort().slice(0, 10);
    await uploadSet(versionLocIds[l], files.map((f) => join(src, f)));
    console.log(`✓ ${files.length} screenshots ${l}`);
  }
}

async function uploadSet(locId, paths) {
  const sets = (await api('GET', `/v1/appStoreVersionLocalizations/${locId}/appScreenshotSets`)).data;
  let set = null;
  for (const displayType of ['APP_IPHONE_67']) {
    set = sets.find((s) => s.attributes.screenshotDisplayType === displayType);
    if (!set) {
      set = (await api('POST', '/v1/appScreenshotSets', { data: { type: 'appScreenshotSets', attributes: { screenshotDisplayType: displayType },
        relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: locId } } } } })).data;
    }
  }
  for (const old of (await api('GET', `/v1/appScreenshotSets/${set.id}/appScreenshots`)).data) {
    await api('DELETE', `/v1/appScreenshots/${old.id}`);
  }
  for (const p of paths) {
    const bytes = readFileSync(p);
    const shot = (await api('POST', '/v1/appScreenshots', { data: { type: 'appScreenshots',
      attributes: { fileName: p.split('/').pop(), fileSize: statSync(p).size },
      relationships: { appScreenshotSet: { data: { type: 'appScreenshotSets', id: set.id } } } } })).data;
    for (const op of shot.attributes.uploadOperations) {
      const headers = Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value]));
      const res = await fetch(op.url, { method: op.method, headers, body: bytes.subarray(op.offset, op.offset + op.length) });
      if (!res.ok) throw new Error(`screenshot upload part failed ${res.status}`);
    }
    await api('PATCH', `/v1/appScreenshots/${shot.id}`, { data: { type: 'appScreenshots', id: shot.id,
      attributes: { uploaded: true, sourceFileChecksum: createHash('md5').update(bytes).digest('hex') } } });
  }
}

console.log('\nDone. Still manual in App Store Connect: App Privacy → "Data Not Collected", attach the build to the version, then Submit for Review.');
