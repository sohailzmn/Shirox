const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const source=fs.readFileSync('Shirox/Services/NetworkFetch.swift','utf8');
const a=source.indexOf('if (sourceDocument) setInterval(function() {'),b=source.indexOf('},500);',a)+7;
let interval,submits=0,clicks=0,proof=null;const messages=[];
const response={value:''},empty={value:''};const button={disabled:false,offsetParent:{},click(){clicks++}};
const sourceContext={value:'opaque-site-context'};
const form={target:'player-iframe',action:'https://serienstream.to/r',querySelectorAll:()=>[empty,response],querySelector:selector=>selector==='altcha-widget'?proof:selector==='input[name="t"]'?sourceContext:button,requestSubmit(value){assert.equal(value,button);submits++}};
const ctx={sourceDocument:true,document:{getElementById:id=>id==='player-prepare-form'?form:null},window:{__shiroxProviderActivated:true,webkit:{messageHandlers:{networkLogger:{postMessage:value=>messages.push(value)}}}},Promise,location:{origin:'https://serienstream.to',href:'https://serienstream.to/serie/dexter'},URL,Array,setInterval:fn=>interval=fn};
vm.runInNewContext(source.slice(a,b),ctx);
interval();assert.equal(submits,0);
response.value='real-site-response-1';interval();assert.equal(submits,1);assert.equal(clicks,0);
interval();assert.equal(submits,1,'single-use response must not be replayed');
response.value='real-site-response-2';interval();assert.equal(submits,2,'fresh site-issued response can retry');
form.action='https://other.example/r';response.value='real-site-response-3';interval();assert.equal(submits,2);
assert.ok(!JSON.stringify(messages).includes('real-site-response'));
console.log('PASS: form-scoped response, native submit without ad clicks, single-use tokens, fresh retry, same-origin restriction, no token logging');

const playerStart=source.indexOf('            const reportPlayerPayload = function() {');
const playerEnd=source.indexOf("            document.addEventListener('DOMContentLoaded', reportPlayerPayload",playerStart);
const playerFunction=source.slice(playerStart,playerEnd).split('\\\\').join('\\');
function playerFixture(passiveDocument,html){
 const sent=[];const context={passiveDocument,location:{pathname:'/e/abc123',href:'https://player.example/e/abc123'},document:{title:'Watch episode - VOE | Content Delivery Network',querySelector:()=>({}),documentElement:{outerHTML:html}},window:{webkit:{messageHandlers:{networkLogger:{postMessage:item=>sent.push(item)}}}}};
 vm.runInNewContext(playerFunction+';reportPlayerPayload();reportPlayerPayload();',context);
 return sent;
}
assert.equal(playerFixture(true,'payload').length,0);
assert.equal(playerFixture(false,'payload').length,1);
assert.equal(playerFixture(false,'x'.repeat(1000001)).length,0);
console.log('PASS: bounded single player capture; protected documents remain passive');

// Evaluate the real document-start guard, before any observer or hook is installed.
const guardStart=source.indexOf("            // Challenge frames");
const guardEnd=source.indexOf("            const sourceHosts",guardStart);
for(const location of [{protocol:'https:',hostname:'challenges.cloudflare.com'},{protocol:'about:',hostname:''}]){
 const untouched={};vm.runInNewContext('(function(){'+source.slice(guardStart,guardEnd).split('\\\\').join('\\')+';window.modified=true})()', {location,document:{referrer:'https://challenges.cloudflare.com/widget'},window:untouched});
 assert.equal(untouched.modified,undefined);
}
const playerBlank={};vm.runInNewContext('(function(){'+source.slice(guardStart,guardEnd).split('\\\\').join('\\')+';window.modified=true})()', {location:{protocol:'about:',hostname:''},document:{referrer:'https://hoster.example/e/episode'},window:playerBlank});
assert.equal(playerBlank.modified,true,'ordinary empty player documents must keep capture');
console.log('PASS: challenge frames untouched; ordinary empty player frames retain capture');

form.action='https://serienstream.to/r';let proofRuns=0,proofState='unverified';
proof={getAttribute:()=>'/api/inline/verify-init',verify(){proofRuns++;proofState='verifying'},getState:()=>proofState};
response.value='';interval();interval();
assert.equal(proofRuns,1,'run the real proof once per widget');assert.equal(submits,2,'an unfinished proof without a Cloudflare response must not submit');
proofState='verified';interval();assert.equal(submits,3,'a genuine verified proof can be submitted without a Cloudflare response');
interval();assert.equal(submits,3,'do not replay a consumed proof');
proof={getAttribute:()=> 'https://other.example/challenge',verify(){throw Error('must not run')},getState:()=> 'unverified'};
interval();assert.equal(submits,3);assert.equal(proof.__shiroxProofStarted,undefined);
response.value='fresh-cloudflare-response';interval();assert.equal(submits,4,'a genuine Cloudflare response remains an alternative');
console.log('PASS: real proof without Cloudflare, no pending or consumed proof submission, same-origin proof, Cloudflare alternative');
const loaderStart=source.indexOf('            const ensureSourceProof = async function');
const loaderEnd=source.indexOf('            if (sourceDocument) setInterval',loaderStart);
const loader=source.slice(loaderStart,loaderEnd),slash=String.fromCharCode(92);
assert.equal(loader.split(slash+slash).join('').includes(slash),false,'JavaScript regex escapes must be doubled inside the Swift literal');
new vm.Script(loader.split(slash+slash).join(slash));
console.log('PASS: source widget loader parses after Swift escape decoding');
(async()=>{
 const decoded=loader.split(slash+slash).join(slash);
 for(const tier of ['turnstile_altcha','none']){
  let touched=false;
  const context={form:{querySelector(){touched=true;throw Error('must not add a duplicate widget')}},root:{dataset:{redirectGateTier:tier}}};
  await vm.runInNewContext('(async()=>{'+decoded+';await ensureSourceProof(form,root)})()',context);
  assert.equal(touched,false,'source-owned proof must not be duplicated');
 }
 const attributes={},proofElement={setAttribute:(name,value)=>attributes[name]=value};let appended=0;
 const localForm={target:'player-iframe',action:'https://serienstream.to/r',isConnected:true,querySelector:()=>appended?proofElement:null,appendChild:()=>appended++};
 const context={form:localForm,root:{dataset:{redirectGateTier:'turnstile',altchaChallengeUrl:'https://serienstream.to/api/inline/verify-init'}},URL,location:{origin:'https://serienstream.to',href:'https://serienstream.to/serie/dexter'},customElements:{get:()=>true},document:{createElement:()=>proofElement}};
 await vm.runInNewContext('(async()=>{'+decoded+';await ensureSourceProof(form,root)})()',context);
 await vm.runInNewContext('(async()=>{'+decoded+';await ensureSourceProof(form,root)})()',context);
 assert.equal(appended,1);assert.equal(attributes.name,'altcha');assert.equal(attributes.challengeurl,'https://serienstream.to/api/inline/verify-init');
 console.log('PASS: source-owned widget is never duplicated; missing proof is installed once');
})().catch(error=>{console.error(error);process.exitCode=1});
const selectionStart=source.indexOf('            window.waitForElementAndClick = function(');
const selectionEnd=source.indexOf('            const reportPlayerPayload',selectionStart);
const selectionScript=source.slice(selectionStart,selectionEnd).split(slash+slash).join(slash);
(async()=>{
 let now=0,clicked=0;const callbacks=[],gate={dataset:{episodeRedirectGateInit:'0'}};
 const provider={offsetParent:{},disabled:false,matches:()=>true,getAttribute:()=>'/r?t=desired-provider',click(){clicked++}};
 const context={Date:{now:()=>now},URL,location:{origin:'https://serienstream.to',href:'https://serienstream.to/serie/dexter'},setTimeout:fn=>callbacks.push(fn),document:{getElementById:()=>gate,querySelector:()=>provider,querySelectorAll:()=>[provider]},window:{webkit:{messageHandlers:{networkLogger:{postMessage(){}}}}}};
 vm.runInNewContext(selectionScript,context);
 const result=context.window.waitForElementAndClick(['provider'],['provider'],3);
 assert.equal(clicked,0,'a button without its site handler must not be activated');
 gate.dataset.episodeRedirectGateInit='1';now=100;callbacks.shift()();await result;
 assert.equal(clicked,1);assert.equal(context.window.__shiroxProviderToken,'desired-provider');
 console.log('PASS: provider activation waits for site initialization and preserves the selected provider context');
})().catch(error=>{console.error(error);process.exitCode=1});

ctx.window.__shiroxProviderToken='selected-provider-context';
proof={__shiroxProofStarted:true,getState:()=> 'verified'};
interval();assert.equal(submits,4,'a proof must not submit the default mirror while a different provider is selected');
sourceContext.value='selected-provider-context';interval();assert.equal(submits,5);
assert.ok(!JSON.stringify(messages).includes('selected-provider-context'));
console.log('PASS: only the selected provider context can consume a verified proof');
