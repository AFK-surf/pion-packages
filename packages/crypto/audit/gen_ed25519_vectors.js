// Ed25519 reference vectors from Node.js crypto (independent implementation) for redteam_test.pion.
const c=require('crypto');
function seedKey(seed){ // PKCS8 DER prefix for ed25519
  const der=Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),seed]);
  return c.createPrivateKey({key:der,format:'der',type:'pkcs8'});
}
const out=[];
for (const [sl, ml] of [[0,0],[1,1],[2,1000],[3,100000]]) {
  const seed=Buffer.alloc(32); for(let i=0;i<32;i++) seed[i]=(i*17+sl*29+5)&255;
  const msg=Buffer.alloc(ml); for(let i=0;i<ml;i++) msg[i]=(i*31+7)&255;
  const k=seedKey(seed);
  const pk=c.createPublicKey(k).export({format:'der',type:'spki'}).subarray(12);
  const sig=c.sign(null,msg,k);
  out.push([sl, ml, seed.toString('hex'), pk.toString('hex'), sig.toString('hex')]);
}
console.log(JSON.stringify(out));
