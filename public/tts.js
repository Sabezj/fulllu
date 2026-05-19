
export function speak(text){
  try{
    const u = new SpeechSynthesisUtterance(String(text||''));
    u.lang = 'ru-RU';
    u.rate = 1.0;
    u.pitch = 1.0;
    speechSynthesis.cancel();
    speechSynthesis.speak(u);
  }catch(e){ console.warn('TTS failed', e); }
}

export function summaryFromStrictResponse(resp){
  const items = resp?.products || resp?.items || [];
  const p = resp?.params_locked || {};
  const fmt = (v, lbl) => (v!=null && v!=='') ? `${lbl} ${v} мм` : null;
  const paramsText = [fmt(p.thickness_mm,'толщина'), fmt(p.width_mm,'ширина'), fmt(p.length_mm,'длина')].filter(Boolean).join(', ') || '—';
  let out = `Нашёл ${items.length} позиций по параметрам: ${paramsText}.`;
  if (items.length>0){
    const top = items[0];
    const price = top.price_rub_per_sheet ?? top.price_rub_per_m2 ?? null;
    const unit  = (top.price_rub_per_sheet ? 'за лист' : (top.price_rub_per_m2 ? 'за м²' : ''));
    out += ` Топ-вариант: ${top.name}, артикул ${top.sku || '—'}` + (price ? `, ${price} ₽ ${unit}.` : '.');
    out += ' Оформляю заказ?';
  }else{
    out += ' Показать близкие альтернативы?';
  }
  return out;
}
