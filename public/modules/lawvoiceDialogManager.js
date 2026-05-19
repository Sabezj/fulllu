const STORAGE_VERSION = 1;

const SCENARIO_BY_INTENT = {
  detention_help: 'detention',
  cyberbullying_help: 'cyberbullying',
  school_rights_help: 'school',
  online_purchase_rights_help: 'online_purchase',
  legal_support_request: 'general_legal',
  emergency_help: 'safety_emergency',
  goodbye: 'general_legal'
};

const FACT_PRIORITIES = {
  detention: ['location', 'immediate_danger', 'adult_support', 'time_ref', 'actors', 'evidence'],
  cyberbullying: ['platform', 'evidence', 'adult_support', 'time_ref', 'actors', 'location'],
  school: ['actors', 'location', 'time_ref', 'adult_support', 'evidence'],
  online_purchase: ['platform', 'time_ref', 'evidence', 'actors', 'adult_support'],
  safety_emergency: ['immediate_danger', 'location', 'adult_support', 'actors', 'time_ref'],
  general_legal: ['actors', 'location', 'time_ref', 'immediate_danger', 'evidence', 'adult_support']
};

const FACT_LABELS = {
  location: 'место',
  time_ref: 'время',
  actors: 'участники',
  platform: 'платформа/канал',
  evidence: 'доказательства',
  immediate_danger: 'прямая угроза',
  adult_support: 'подключенный взрослый'
};

function createEmptyState() {
  return {
    version: STORAGE_VERSION,
    stage: 'triage',
    scenario: 'unknown',
    risk_level: 'unknown',
    clarification_count: 0,
    last_intent: null,
    facts: {
      location: null,
      time_ref: null,
      actors: null,
      platform: null,
      evidence: null,
      immediate_danger: null,
      adult_support: null
    },
    history: [],
    updated_at: Date.now()
  };
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function safeParse(json) {
  if (!json || typeof json !== 'string') return null;
  try {
    return JSON.parse(json);
  } catch {
    return null;
  }
}

function normalizeRisk(risk) {
  const raw = `${risk || ''}`.toLowerCase();
  if (raw.includes('high') || raw.includes('выс')) return 'high';
  if (raw.includes('low') || raw.includes('низ')) return 'low';
  if (raw.includes('med') || raw.includes('сред')) return 'medium';
  return 'unknown';
}

export default class LawVoiceDialogManager {
  constructor({ storage = null, storageKey = 'lawvoice.dialog.state.v1', maxHistory = 10 } = {}) {
    this.storage = storage;
    this.storageKey = storageKey;
    this.maxHistory = maxHistory;
    this.state = createEmptyState();
    this._restore();
  }

  setStorageKey(storageKey) {
    if (!storageKey || storageKey === this.storageKey) return;
    this.storageKey = storageKey;
    this._restore();
  }

  getStateSnapshot() {
    return clone(this.state);
  }

  reset(reason = 'manual') {
    this.state = createEmptyState();
    this.state.history.push({
      ts: Date.now(),
      kind: 'reset',
      reason
    });
    this._persist();
    return this.getStateSnapshot();
  }

  resetClarificationCount() {
    this.state.clarification_count = 0;
    this.state.updated_at = Date.now();
    this._persist();
  }

  extractFactsFromText(transcript = '') {
    const text = `${transcript || ''}`;
    const lowered = text.toLowerCase();
    const facts = {};

    if (/(в\s+школе|школ[аеу]|класс|в\s+лицее|в\s+колледже)/i.test(lowered)) facts.location = 'школа';
    else if (/(в\s+отделе|в\s+полиции|отдел\s+полиции|в\s+овд)/i.test(lowered)) facts.location = 'отдел полиции';
    else if (/(дома|на\s+улице|во\s+дворе|в\s+интернете)/i.test(lowered)) facts.location = (lowered.match(/дома|на\s+улице|во\s+дворе|в\s+интернете/i) || [])[0] || null;

    if (/(сейчас|прямо\s+сейчас|только\s+что|сегодня|вчера|недавно)/i.test(lowered)) {
      facts.time_ref = (lowered.match(/сейчас|прямо\s+сейчас|только\s+что|сегодня|вчера|недавно/i) || [])[0] || 'недавно';
    }

    if (/(полици|сотрудник|учител|однокласс|продав|поддержк|модератор|родител)/i.test(lowered)) {
      facts.actors = (lowered.match(/полици\w*|сотрудник\w*|учител\w*|однокласс\w*|продав\w*|поддержк\w*|модератор\w*|родител\w*/i) || [])[0] || null;
    }

    if (/(телеграм|telegram|vk|вк|whatsapp|чат|дискорд|discord|instagram|тикток|tiktok|маркетплейс|ozon|wildberries)/i.test(lowered)) {
      facts.platform = (lowered.match(/телеграм|telegram|vk|вк|whatsapp|чат|дискорд|discord|instagram|тикток|tiktok|маркетплейс|ozon|wildberries/i) || [])[0] || null;
    }

    if (/(скрин|чек|квитанц|видео|аудио|запис|переписк|доказат)/i.test(lowered)) facts.evidence = true;
    if (/(нет\s+скрин|без\s+доказ|ничего\s+не\s+сохранил|не\s+сохранил)/i.test(lowered)) facts.evidence = false;

    if (/(угрож|опасно|боюсь|страшно|бьют|насили|вымог|шантаж|преслед)/i.test(lowered)) facts.immediate_danger = true;
    if (/(безопасно|угроз\s+нет|все\s+спокойно)/i.test(lowered)) facts.immediate_danger = false;

    if (/(сказал\s+родител|сообщил\s+родител|рядом\s+мама|рядом\s+папа|обратил[а-я]*\s+к\s+учител)/i.test(lowered)) facts.adult_support = true;
    if (/(не\s+говорил\s+родител|взросл(ому|ым)\s+не\s+говорил|никому\s+не\s+сказал)/i.test(lowered)) facts.adult_support = false;

    return facts;
  }

  registerIntent({ intentName, transcript = '', params = {}, meta = {} } = {}) {
    const scenario = this._inferScenario(intentName, transcript, params);
    const extractedFacts = this.extractFactsFromText(transcript);
    const mergedFacts = this._mergeFacts(this.state.facts, extractedFacts, params);
    const risk = this._inferRisk(intentName, transcript, params, mergedFacts);
    const stage = this._deriveStage(intentName, scenario, risk, mergedFacts);
    const nextQuestion = this._pickNextQuestion(scenario, mergedFacts);

    this.state.scenario = scenario;
    this.state.facts = mergedFacts;
    this.state.risk_level = risk;
    this.state.stage = stage;
    this.state.last_intent = intentName || null;
    this.state.updated_at = Date.now();
    if (intentName && intentName !== 'clarify_intent') {
      this.state.clarification_count = 0;
    }
    this._appendHistory({
      ts: Date.now(),
      kind: 'intent',
      intent: intentName || 'unknown',
      transcript,
      stage,
      scenario,
      risk
    });
    this._persist();

    return {
      state: this.getStateSnapshot(),
      scenario,
      risk_level: risk,
      stage,
      next_question: nextQuestion,
      directive: this._buildDirective({
        intentName,
        transcript,
        params,
        meta,
        scenario,
        stage,
        risk,
        facts: mergedFacts,
        nextQuestion
      })
    };
  }

  buildClarificationPrompt({ fallbackText = '', transcript = '' } = {}) {
    const extractedFacts = this.extractFactsFromText(transcript);
    const scenario = this._inferScenario(null, transcript, {});
    if (this.state.scenario === 'unknown' && scenario !== 'unknown') {
      this.state.scenario = scenario;
    }
    this.state.facts = this._mergeFacts(this.state.facts, extractedFacts, {});
    this.state.clarification_count += 1;
    this.state.stage = this.state.stage === 'unknown' ? 'triage' : this.state.stage;
    this.state.updated_at = Date.now();

    const guessScenario = this.state.scenario === 'unknown' ? 'general_legal' : this.state.scenario;
    const nextQuestion = this._pickNextQuestion(guessScenario, this.state.facts);

    let prompt = fallbackText || 'Я рядом. Уточните, пожалуйста, что произошло.';
    if (this.state.clarification_count <= 1) {
      prompt = `${prompt} ${nextQuestion || 'Опишите в 1-2 фразах, что случилось и есть ли срочность.'}`;
    } else if (this.state.clarification_count === 2) {
      prompt = 'Чтобы помочь быстрее, выберите тему: 1) задержание/полиция, 2) кибербуллинг, 3) школа, 4) покупка в интернете. Если есть угроза — сразу скажите об этом.';
    } else {
      prompt = 'Нужен быстрый выбор: задержание, кибербуллинг, школа или покупка в интернете? Если есть опасность прямо сейчас — звоните 112.';
    }

    this._appendHistory({
      ts: Date.now(),
      kind: 'clarify',
      transcript,
      prompt
    });
    this._persist();
    return {
      prompt,
      state: this.getStateSnapshot()
    };
  }

  _inferScenario(intentName, transcript, params) {
    if (params?.scenario && typeof params.scenario === 'string') return params.scenario;
    if (intentName && SCENARIO_BY_INTENT[intentName]) return SCENARIO_BY_INTENT[intentName];
    const lowered = `${transcript || ''}`.toLowerCase();
    if (/(задерж|полици|мусора|протокол|адвокат)/i.test(lowered)) return 'detention';
    if (/(кибербуллинг|буллинг|травл|чат|соцсет|аккаунт|слив)/i.test(lowered)) return 'cyberbullying';
    if (/(школ|учител|директор|класс|однокласс)/i.test(lowered)) return 'school';
    if (/(покупк|маркетплейс|доставк|возврат|чек|продавец)/i.test(lowered)) return 'online_purchase';
    if (/(угрож|насили|вымог|шантаж|опасно)/i.test(lowered)) return 'safety_emergency';
    if (/(помощ|совет|консультац|что\s+делать)/i.test(lowered)) return 'general_legal';
    return this.state.scenario !== 'unknown' ? this.state.scenario : 'unknown';
  }

  _inferRisk(intentName, transcript, params, facts) {
    const fromParams = normalizeRisk(params?.risk_level || params?.urgency);
    if (fromParams !== 'unknown') return fromParams;
    if (intentName === 'emergency_help' || intentName === 'detention_help') return 'high';
    if (facts.immediate_danger === true) return 'high';
    const lowered = `${transcript || ''}`.toLowerCase();
    if (/(угрож|опасно|боюсь|насили|вымог|шантаж|преслед)/i.test(lowered)) return 'high';
    if (/(кибербуллинг|буллинг|задерж|школ|конфликт)/i.test(lowered)) return 'medium';
    if (/(покупк|заказ|возврат)/i.test(lowered)) return 'low';
    return this.state.risk_level !== 'unknown' ? this.state.risk_level : 'medium';
  }

  _mergeFacts(prevFacts, extractedFacts, params) {
    const merged = { ...(prevFacts || {}) };
    for (const [key, value] of Object.entries(extractedFacts || {})) {
      if (value !== null && value !== undefined && value !== '') merged[key] = value;
    }
    if (params?.platform) merged.platform = params.platform;
    if (params?.query_text && !merged.actors) merged.actors = params.query_text.slice(0, 80);
    if (params?.urgency === 'high') merged.immediate_danger = true;
    return merged;
  }

  _deriveStage(intentName, scenario, risk, facts) {
    if (intentName === 'goodbye') return 'follow_up';
    if (scenario === 'safety_emergency' || risk === 'high' || facts.immediate_danger === true) return 'safety';

    const keys = FACT_PRIORITIES[scenario] || FACT_PRIORITIES.general_legal;
    const knownCount = keys.reduce((acc, key) => {
      const value = facts[key];
      return value === null || value === undefined ? acc : acc + 1;
    }, 0);

    if (knownCount <= 1) return 'fact_gathering';
    if (knownCount <= 3) return 'options';
    return 'action_plan';
  }

  _pickNextQuestion(scenario, facts) {
    const keys = FACT_PRIORITIES[scenario] || FACT_PRIORITIES.general_legal;
    const firstMissing = keys.find((key) => facts[key] === null || facts[key] === undefined);
    if (!firstMissing) return 'Что уже сделали, и какой результат хотите получить в ближайшие 24 часа?';

    const prompts = {
      location: 'Где это происходит прямо сейчас?',
      time_ref: 'Когда это произошло: сейчас, сегодня или раньше?',
      actors: 'Кто именно участвует в ситуации?',
      platform: 'Где это происходит: какой чат, соцсеть или платформа?',
      evidence: 'Есть ли у вас скриншоты, сообщения или другие доказательства?',
      immediate_danger: 'Есть ли сейчас прямая угроза вашей безопасности?',
      adult_support: 'Есть ли взрослый, которому вы уже сообщили и кому доверяете?'
    };
    return prompts[firstMissing] || 'Уточните, пожалуйста, ключевые факты.';
  }

  _buildDirective({ intentName, transcript, scenario, stage, risk, facts, nextQuestion, meta }) {
    const knownFacts = Object.entries(facts || {})
      .filter(([, value]) => value !== null && value !== undefined)
      .map(([key, value]) => `${FACT_LABELS[key] || key}: ${String(value)}`);
    const factsText = knownFacts.length > 0 ? knownFacts.join('; ') : 'фактов пока мало';

    const stageRules = {
      safety: 'Сначала безопасность: короткая поддержка, проверка рисков, действия на 10 минут, подключение взрослого, 112 при прямой угрозе.',
      fact_gathering: 'Коротко поддержи и задай ровно один уточняющий вопрос, чтобы закрыть критичный пробел в фактах.',
      options: 'Дай 2-3 правомерных варианта действий с последствиями каждого, затем предложи лучший следующий шаг.',
      action_plan: 'Собери конкретный план на 24 часа (нумерованный), включая фиксацию доказательств и безопасную эскалацию.',
      follow_up: 'Коротко и уважительно завершай диалог, напомни что можно вернуться за помощью.'
    };

    const emergencyLine = risk === 'high' ? 'Если есть угроза жизни/здоровью, обязательно скажи про 112.' : '';
    const toneLine = meta?.reply ? `Тон ответа: ${meta.reply}` : 'Тон: спокойный, уважительный, без запугивания.';

    return [
      'LawVoice Dialog Manager Context',
      `Сценарий: ${scenario}`,
      `Стадия: ${stage}`,
      `Риск: ${risk}`,
      `Последний интент: ${intentName || 'unknown'}`,
      `Последняя фраза пользователя: "${transcript}"`,
      `Известные факты: ${factsText}`,
      stageRules[stage] || stageRules.fact_gathering,
      `Контрольный вопрос: ${nextQuestion}`,
      emergencyLine,
      toneLine
    ]
      .filter(Boolean)
      .join('\n');
  }

  _appendHistory(entry) {
    this.state.history.push(entry);
    if (this.state.history.length > this.maxHistory) {
      this.state.history = this.state.history.slice(-this.maxHistory);
    }
  }

  _restore() {
    if (!this.storage?.getItem) return;
    const raw = this.storage.getItem(this.storageKey);
    const parsed = safeParse(raw);
    if (!parsed || parsed.version !== STORAGE_VERSION) return;
    this.state = {
      ...createEmptyState(),
      ...parsed,
      facts: {
        ...createEmptyState().facts,
        ...(parsed.facts || {})
      },
      history: Array.isArray(parsed.history) ? parsed.history : []
    };
  }

  _persist() {
    if (!this.storage?.setItem) return;
    try {
      this.storage.setItem(this.storageKey, JSON.stringify(this.state));
    } catch {
      // Ignore quota/storage errors silently to keep runtime stable.
    }
  }
}
