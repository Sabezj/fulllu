// node_patch/intentHandlers.sample.js
// Пример: как вызывать хендлеры без `this.say` — явно пробрасывая say()

const { searchProducts, listProducts } = require('./services/searchClient'); // скорректируйте путь под свой проект

async function handleSearchProducts(ctx, say) {
  const q = (ctx.query || ctx.text || '').trim();
  if (!q) {
    await say("Уточните, пожалуйста, что именно ищете.");
    return;
  }
  await say("Секунду, проверю по каталогу…");
  try {
    const items = await searchProducts(q, 10);
    if (!items || items.length === 0) {
      await say("К сожалению, по вашему запросу ничего не нашлось. Попробуем иначе сформулировать?");
      return;
    }
    const top = items.slice(0, 3).map((p, i) => `${i+1}) ${p.name} — ${p.price_rub_m2} руб/м²`).join("; ");
    await say(`Нашёл варианты: ${top}. Какой подойдёт?`);
  } catch (e) {
    if (e.code === 'search_down') {
      await say("Каталог временно недоступен. Могу соединить с менеджером или перезвонить позже — как удобнее?");
    } else {
      await say("Произошла ошибка при поиске. Давайте попробуем сформулировать запрос по‑другому.");
    }
  }
}

async function handleListProducts(ctx, say) {
  await say("Секунду, открою каталог…");
  try {
    const items = await listProducts(10);
    if (!items || items.length === 0) {
      await say("Сейчас каталог пуст. Давайте соединю с менеджером.");
      return;
    }
    const top = items.slice(0, 5).map((p, i) => `${i+1}) ${p.name} — ${p.price_rub_m2} руб/м²`).join("; ");
    await say(`Первые позиции: ${top}. Что именно интересует?`);
  } catch (e) {
    if (e.code === 'search_down') {
      await say("Каталог временно недоступен. Соединяю с менеджером?");
    } else {
      await say("Не получилось получить список. Попробуем позже.");
    }
  }
}

module.exports = {
  handleSearchProducts,
  handleListProducts
};