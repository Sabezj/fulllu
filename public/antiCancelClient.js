
export async function registerTtsStart(){
  try{
    const r = await fetch('/api/voice/register-tts-start', { method: 'POST', headers: { 'Content-Type':'application/json' }, body: JSON.stringify({}) });
    return await r.json();
  }catch(e){ return { ok:false, error:String(e) }; }
}

export async function maybeCancel({ vadActiveMs=0, rmsDb=0 } = {}){
  try{
    const r = await fetch('/api/voice/maybe-cancel', {
      method: 'POST',
      headers: { 'Content-Type':'application/json' },
      body: JSON.stringify({ vadActiveMs, rmsDb })
    });
    return await r.json();
  }catch(e){ return { ok:false, error:String(e) }; }
}
