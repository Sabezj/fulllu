/**
 * OpenAI Realtime Voice Agent with WebRTC
 * Implements secure ephemeral token authentication and real-time audio streaming
 */

// Logger for client-side error tracking
import { resetTokenUsage as resetTokenUsageFn, getTotalTokens as getTotalTokensFn, updateTokenDisplay as updateTokenDisplayFn, updateCostDisplay as updateCostDisplayFn, updatePricingDisplay as updatePricingDisplayFn } from "./modules/pricing.js";
import { setupInputAudioAnalysis as setupInputAudioAnalysisFn, setupOutputAudioAnalysis as setupOutputAudioAnalysisFn, drawVisualization as drawVisualizationFn, drawWaveform as drawWaveformFn, getAudioLevel as getAudioLevelFn, updateLevelMeter as updateLevelMeterFn, detectVoiceActivity as detectVoiceActivityFn } from "./modules/audio.js";
import { strictSearchByParams } from './strictSearchClient.js';
import LawVoiceDialogManager from './modules/lawvoiceDialogManager.js';

window.logger = window.logger || console;
const logger = window.logger;
const COMMERCE_CATALOG_ENABLED = window.LAWVOICE_COMMERCE_CATALOG_ENABLED === true;
const ADMIN_ONLY_TOOL_NAMES = new Set([
  'search_products',
  'list_products',
  'list_categories',
  'add_to_cart',
  'checkout',
  'cancel_order'
]);
function normalizeSpecAttrs(rawParams = {}) {
  // Берём атрибуты отовсюду: attrs | filters | specs | сам корень
  const src = {
    ...(rawParams.attrs || {}),
    ...(rawParams.filters || {}),
    ...(rawParams.specs || {}),
    ...rawParams
  };

  // Алиасы ключей
  const aliasMap = {
    thickness: 'thickness',
    thickness_mm: 'thickness',
    width: 'width',
    width_mm: 'width',
    length: 'length',
    length_mm: 'length',
    qty: 'quantity',
    quantity: 'quantity',
    category: 'category',
    material: 'material',
    coating: 'coating'
  };

  // helper: вытащить число и (по желанию) привести метры → мм
  const toNumberMaybeMM = (val) => {
    if (val == null) return undefined;
    const s = String(val).trim().toLowerCase().replace(',', '.');
    // match: число + опционально пробел + ед-ца
    const m = s.match(/([0-9]*\.?[0-9]+)\s*(мм|миллиметр|миллиметра|миллиметров|см|сантиметр|сантиметра|сантиметров|м|метр|метра|метров)?/i);
    if (!m) return undefined;
    const num = parseFloat(m[1]);
    const unit = m[2] || ''; // если пусто — считаем мм
    if (!isFinite(num)) return undefined;
    const unitMul = unit.startsWith('см') || unit.includes('сантим')
        ? 10
        : (unit === 'м' || unit.startsWith('метр') ? 1000 : 1);
    return num * unitMul; // в мм
  };

  const out = {};
  for (const [k, v] of Object.entries(src)) {
    const normKey = aliasMap[k];
    if (!normKey) continue;
    if (['thickness', 'width', 'length'].includes(normKey)) {
      const mm = toNumberMaybeMM(v);
      if (mm != null) out[normKey] = mm;
    } else if (normKey === 'quantity') {
      const q = parseInt(String(v).replace(/\D+/g, ''), 10);
      if (Number.isFinite(q)) out.quantity = q;
    } else {
      // строковые фильтры (category/material/coating)
      const s = String(v).trim();
      if (s) out[normKey] = s;
    }
  }
  return out;
}

function pruneParamsToUtterance(params = {}, utterance = '') {
  const u = (utterance || '').toLowerCase();

  // разрешённые ключи
  const allowed = ['thickness','thickness_mm','width','width_mm','length','length_mm','quantity','qty','category','material','coating','query_text'];

  // хелперы: проверяем, упоминалось ли в ТЕКУЩЕЙ реплике
  const said = {
    thickness: /\b(толщин\w*|0?\.\d+|[0-9]+[,\.]?[0-9]*\s*мм)\b/i.test(u),
    width: /\b(ширин\w*|[0-9]+[,\.]?[0-9]*\s*(мм|см|м))\b/i.test(u),
    length: /\b(длин\w*|[0-9]+[,\.]?[0-9]*\s*(мм|см|м))\b/i.test(u),
    quantity: /\b(количеств\w*|штук|лист(а|ов)?|по\s*\d+|x\s*\d+)\b/i.test(u),
    category: /\b(лист(ы)?|профнастил|профилированн\w*\s*лист)\b/i.test(u),
    material: /\b(оцинк|сталь|алюмини|нержаве\w*)\b/i.test(u),
    coating: /\b(покрыти\w*|без\s+покрыти\w*|полиэстер|пурал|цинк)\b/i.test(u)
  };

  const out = {};
  for (const [k, v] of Object.entries(params)) {
    if (!allowed.includes(k)) continue;

    // мэппим ключ к «сигналу» из текущей фразы
    const gateKey =
        k.startsWith('thickness') ? 'thickness' :
            k.startsWith('width')     ? 'width' :
                k.startsWith('length')    ? 'length' :
                    (k === 'qty' || k === 'quantity') ? 'quantity' :
                        k; // category/material/coating/query_text

    // пропускаем только если это явно проговорено ИЛИ это query_text
    if (gateKey === 'query_text' || said[gateKey]) out[k] = v;
  }
  return out;
}

async function readErrorMessage(response) {
  const fallback = `${response.status} ${response.statusText}`.trim();
  let text = '';

  try {
    text = await response.text();
  } catch {
    return fallback;
  }

  const trimmed = text.trim();
  if (!trimmed) return fallback;

  try {
    const data = JSON.parse(trimmed);
    if (typeof data?.error === 'string' && data.error.trim()) return data.error.trim();
    if (typeof data?.message === 'string' && data.message.trim()) return data.message.trim();
    if (typeof data?.details === 'string' && data.details.trim()) return data.details.trim();
    if (typeof data?.details?.error?.message === 'string' && data.details.error.message.trim()) {
      return data.details.error.message.trim();
    }
  } catch {
    // Ignore JSON parse errors and use raw text.
  }

  return trimmed;
}
class VoiceAgent {
  
  cancelResponseSafely() {
    try {
      if (this.isAssistantSpeaking || this.activeResponseId) {
        this.agentLog('Cancelling active response');
        this.cancelResponse?.(); // SDK method if available
      } else {
        this.agentLog('Skip cancel: no active response');
      }
    } catch (e) {
      console.warn('Cancel failed (guarded):', e?.message || e);
    }
  }

  say(...args) { try { return this.sendContextText?.(...args); } catch(e) { console.warn('say shim failed', e?.message||e); } }
  constructor() {
    this.pc = null; // WebRTC PeerConnection
    this.dataChannel = null;
    this.mediaStream = null;
    this.audioContext = null;
    this.inputAnalyser = null;
    this.outputAnalyser = null;
    this.outputAudioElement = null;
    this.sessionData = null;
    this.isConnected = false;
    this.isMuted = false;
    this.eventLog = [];

    // Reconnection tracking for WebRTC
    this.reconnectAttempts = 0;

    // Voice interruption tracking
    this.isAssistantSpeaking = false;
    this.hasActiveResponse = false; // Track if there's an active response that can be cancelled
    this.voiceActivityThreshold = 0.02; // Ignore low ambient mic noise
    this.voiceActivityDuration = 0;
    this.voiceActivityCountThreshold = 40; // Require sustained speech before interrupting
    this.lastVoiceActivityCheck = 0;
    this.lastResponseCreatedAt = 0;
    this.minInterruptResponseAgeMs = 800;

    // Token tracking
    this.tokenUsage = {
      inputTextTokens: 0,
      inputAudioTokens: 0,
      outputTextTokens: 0,
      outputAudioTokens: 0
    };
    this.sessionCostLimitUsd = Number.POSITIVE_INFINITY;
    this.costLimitReached = false;

    // Model temperature control
    this.defaultTemperature = 0.7;
    this.temperature = this.defaultTemperature;
    this.temperatureBoosted = false;

    // Analytics tracking
    this.sessionStartTime = null;
    this.queryCount = 0;
    this.sessionsChart = null;
    this.tokensChart = null;
    this.sessionRecordLocalId = null;
    this.sessionTranscript = [];
    this.sessionEvents = [];
    this.sessionRecordingSaved = false;

    // Pricing configuration (per 1M tokens) - Updated with correct OpenAI pricing
    this.pricing = {
      // Realtime API pricing for GPT-4o (default model)
      textInput: 5.00,      // Text input tokens
      textInputCached: 2.50, // Cached text input tokens
      audioInput: 40.00,    // Audio input tokens  
      audioInputCached: 2.50, // Cached audio input tokens
      textOutput: 20.00,    // Text output tokens
      audioOutput: 80.00    // Audio output tokens
    };

    // Model-specific pricing configurations
    this.modelPricing = {
      "gpt-4o-realtime-preview": {
        textInput: 5.00,
        textInputCached: 2.50,
        audioInput: 40.00,
        audioInputCached: 2.50,
        textOutput: 20.00,
        audioOutput: 80.00
      },
      "gpt-4o-mini-realtime-preview": {
        textInput: 0.60,
        textInputCached: 0.30,
        audioInput: 10.00,
        audioInputCached: 0.30,
        textOutput: 2.40,
        audioOutput: 20.00
      },
      "gpt-realtime-mini": {
        textInput: 0.60,
        textInputCached: 0.30,
        audioInput: 10.00,
        audioInputCached: 0.30,
        textOutput: 2.40,
        audioOutput: 20.00
      },
      "gpt-4o-realtime-preview-2025-06-03": {
        textInput: 5.00,
        textInputCached: 2.50,
        audioInput: 40.00,
        audioInputCached: 2.50,
        textOutput: 20.00,
        audioOutput: 80.00
      }
    };

    // Audio visualization
    this.canvas = document.getElementById('audio-canvas');
    this.canvasCtx = this.canvas.getContext('2d');
    this.animationId = null;
    this.inputLevelData = new Uint8Array(128);
    this.outputLevelData = new Uint8Array(128);

    // UI elements
    this.elements = {
      startBtn: document.getElementById('start-session'),
      stopBtn: document.getElementById('stop-session'),
      muteBtn: document.getElementById('mute-btn'),
      statusConnection: document.getElementById('status-connection'),
      statusVoice: document.getElementById('status-voice'),
      statusModel: document.getElementById('status-model'),
      adminRoleBadge: document.getElementById('admin-role-badge'),
      adminAuthStatus: document.getElementById('admin-auth-status'),
      adminLoginError: document.getElementById('admin-login-error'),
      adminLoginForm: document.getElementById('admin-login-form'),
      adminLoginKey: document.getElementById('admin-login-key'),
      adminLoginBtn: document.getElementById('admin-login-btn'),
      adminLogoutBtn: document.getElementById('admin-logout-btn'),
      conversationLog: document.getElementById('conversation-log'),
      activityLog: document.getElementById('agent-activity-log'),
      clearLogBtn: document.getElementById('clear-log'),
      inputLevel: document.getElementById('input-level'),
      outputLevel: document.getElementById('output-level'),
      debugContent: document.getElementById('debug-content'),
      sessionInfo: document.getElementById('session-info'),
      eventLog: document.getElementById('event-log'),
      contextInput: document.getElementById('context-input'),
      sendContextBtn: document.getElementById('send-context'),
      interruptContext: document.getElementById('interrupt-context'),
      backgroundContext: document.getElementById('background-context'),
      aiInstructions: document.getElementById('ai-instructions'),
      systemPrompt: document.getElementById('system-prompt'),
      // Token counter elements
      inputTextTokens: document.getElementById('input-text-tokens'),
      inputAudioTokens: document.getElementById('input-audio-tokens'),
      outputTextTokens: document.getElementById('output-text-tokens'),
      outputAudioTokens: document.getElementById('output-audio-tokens'),
      totalTokens: document.getElementById('total-tokens'),
      inputTextCost: document.getElementById('input-text-cost'),
      inputAudioCost: document.getElementById('input-audio-cost'),
      outputTextCost: document.getElementById('output-text-cost'),
      outputAudioCost: document.getElementById('output-audio-cost'),
      totalCost: document.getElementById('total-cost'),
      currentModel: document.getElementById('current-model'),
      priceTextInput: document.getElementById('price-text-input'),
      priceAudioInput: document.getElementById('price-audio-input'),
      priceTextOutput: document.getElementById('price-text-output'),
      priceAudioOutput: document.getElementById('price-audio-output'),
      priceTextInputCached: document.getElementById('price-text-input-cached'),
      priceAudioInputCached: document.getElementById('price-audio-input-cached'),
      viewProductsBtn: document.getElementById('view-products'),
      productSearch: document.getElementById('product-search'),
      productList: document.getElementById('product-list'),
      csrfToken: document.getElementById('csrf-token'),
      orderForm: document.getElementById('order-form'),
      orderProductId: document.getElementById('order-product-id'),
      cartTableBody: document.getElementById('cart-table-body'),
      cartTotal: document.getElementById('cart-total'),
      submitOrderBtn: document.getElementById('submit-order'),
      profileSelect: document.getElementById('profile-select'),
      activeProfile: document.getElementById('active-profile'),
      ageModeSelect: document.getElementById('age-mode'),
      profileDetails: document.getElementById('profile-details'),
      adaptiveModeState: document.getElementById('adaptive-mode-state'),
      profileName: document.getElementById('profile-name'),
      profileVoice: document.getElementById('profile-voice'),
      profileMood: document.getElementById('profile-mood'),
      profileRules: document.getElementById('profile-rules'),
      profileInstructions: document.getElementById('profile-instructions'),
      saveProfileBtn: document.getElementById('save-profile'),
      loadProfileBtn: document.getElementById('load-profile'),
      profileFile: document.getElementById('profile-file'),
      enableVector: document.getElementById('enable-vector'),
      enableTrigram: document.getElementById('enable-trigram'),
      knowledgeTitle: document.getElementById('knowledge-title'),
      knowledgeFile: document.getElementById('knowledge-file'),
      uploadKnowledgeBtn: document.getElementById('upload-knowledge'),
      refreshKnowledgeBtn: document.getElementById('refresh-knowledge'),
      knowledgeSearch: document.getElementById('knowledge-search'),
      knowledgeStatus: document.getElementById('knowledge-status'),
      knowledgeDocumentsBody: document.getElementById('knowledge-documents-body'),
      grafanaLink: document.getElementById('grafana-link'),
      prometheusLink: document.getElementById('prometheus-link'),
      metricsLink: document.getElementById('metrics-link'),
      observabilityStatus: document.getElementById('observability-status')
    };

    this.profiles = [];
    this.currentProfile = null;
    this.baseEngineProfile = null;
    this.adaptiveSwitchProfile = null;
    this.promptRuntime = {
      ageMode: this.elements.ageModeSelect?.value || 'teen',
      anxiety: 'medium',
      risk: 'low',
      forcedSafety: false,
      emergencyEscalation: false,
      requestedProfileId: null,
      effectiveProfileId: null
    };
    this.products = [];
    this.cart = JSON.parse(localStorage.getItem('cart') || '[]');
    this.lastSearchResults = [];
    this.phase = 'idle';
    this.lawVoiceDialog = new LawVoiceDialogManager({
      storage: window.localStorage,
      storageKey: 'lawvoice.dialog.state.v1'
    });
    this.intentDialogState = this.lawVoiceDialog.getStateSnapshot();
    this.currentUserId = null;
    this.previousOrders = [];
    this.orderDetails = { delivery_address: '', contact_name: '', contact_phone: '', agreement: false };
    this.cartTotal = 0;
    this.knowledgeDocuments = [];
    this.knowledgeSearchTimer = null;
    this.currentActionPlan = null;
    this.lastActionPlanObjective = '';
    this.lastActionPlanRequestedAt = 0;
    this.awaitingConfirmation = false;
    this.authState = { role: 'user', isAdmin: false, canManage: false, observability: null };
    this.setupEventListeners();
    this.setupCanvas();
    this.updateTokenDisplay();
    this.updatePricingDisplay();
    this.fetchCsrfToken();
    this.renderCart();
    this.loadProfiles();
    this.refreshAuthState({ silent: true });
  }

  setupEventListeners() {
    this.elements.startBtn.addEventListener('click', () => this.startSession());
    this.elements.stopBtn.addEventListener('click', () => this.stopSession());
    this.elements.muteBtn.addEventListener('click', () => this.toggleMute());
    this.elements.clearLogBtn.addEventListener('click', () => this.clearConversationLog());
    window.addEventListener('pagehide', () => this.sendSessionRecordingBeacon('page_unload'));
    if (this.elements.adminLoginForm) {
      this.elements.adminLoginForm.addEventListener('submit', (event) => this.submitAdminLogin(event));
    }
    if (this.elements.adminLogoutBtn) {
      this.elements.adminLogoutBtn.addEventListener('click', () => this.logoutAdmin());
    }
    if (this.elements.viewProductsBtn) {
      this.elements.viewProductsBtn.addEventListener('click', () => this.loadProducts());
    }
    if (this.elements.productSearch) {
      this.elements.productSearch.addEventListener('input', (e) => this.filterProducts(e.target.value));
    }
    if (this.elements.uploadKnowledgeBtn) {
      this.elements.uploadKnowledgeBtn.addEventListener('click', () => this.uploadKnowledgeDocument());
    }
    if (this.elements.refreshKnowledgeBtn) {
      this.elements.refreshKnowledgeBtn.addEventListener('click', () => this.loadKnowledgeDocuments());
    }
    if (this.elements.knowledgeSearch) {
      this.elements.knowledgeSearch.addEventListener('input', () => {
        clearTimeout(this.knowledgeSearchTimer);
        this.knowledgeSearchTimer = setTimeout(() => {
          this.loadKnowledgeDocuments();
        }, 250);
      });
    }
    if (this.elements.submitOrderBtn) {
      this.elements.submitOrderBtn.addEventListener('click', () => this.submitOrder());
    }

    if (this.elements.profileSelect) {
      this.elements.profileSelect.addEventListener('change', () => {
        const id = this.elements.profileSelect.value;
        const profile = this.profiles.find(p => p.id === id);
        this.applyProfile(profile);
      });
    }

    if (this.elements.ageModeSelect) {
      this.elements.ageModeSelect.addEventListener('change', () => {
        this.promptRuntime.ageMode = this.elements.ageModeSelect.value || 'teen';
        this.updateAdaptiveModeBadge();
        this.rebuildLawVoicePrompt('age_mode_changed');
      });
    }

    if (this.elements.profileInstructions && this.elements.aiInstructions) {
      this.elements.profileInstructions.addEventListener('input', (e) => {
        if (!this.isLawVoiceMode()) {
          this.elements.aiInstructions.value = e.target.value;
        }
      });
    }

    if (this.elements.loadProfileBtn && this.elements.profileFile) {
      this.elements.loadProfileBtn.addEventListener('click', () => {
        this.elements.profileFile.click();
      });
      this.elements.profileFile.addEventListener('change', async (e) => {
        const file = e.target.files[0];
        if (!file) return;
        try {
          const text = await file.text();
          const json = JSON.parse(text);
          this.applyProfile(json);
        } catch (err) {
          logger.error('Failed to load profile file', err);
        }
      });
    }

    if (this.elements.saveProfileBtn) {
      this.elements.saveProfileBtn.addEventListener('click', () => {
        const profile = {
          name: this.elements.profileName?.value || '',
          voice: this.elements.profileVoice?.value || '',
          mood: this.elements.profileMood?.value || '',
          rules: this.elements.profileRules?.value || '',
          instructions: this.elements.profileInstructions?.value || ''
        };
        const blob = new Blob([JSON.stringify(profile, null, 2)], { type: 'application/json' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = `${profile.name || 'profile'}.json`;
        a.click();
      });
    }

    // Context injection event listeners
    this.elements.contextInput.addEventListener('input', () => this.updateContextButton());
    this.elements.sendContextBtn.addEventListener('click', () => this.sendContext());

    // Enable send button when session is connected
    this.elements.contextInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault();
        if (!this.elements.sendContextBtn.disabled) {
          this.sendContext();
        }
      }
    });
  }

  async loadProfiles() {
    if (!this.elements.profileSelect) return;
    try {
      const res = await fetch('/api/profiles');
      const allProfiles = (await res.json()).sort((a, b) => (a.name || '').localeCompare(b.name || '', 'ru'));

      this.baseEngineProfile =
        allProfiles.find(p => `${p.id || ''}`.toLowerCase() === 'base_engine') || null;
      this.adaptiveSwitchProfile =
        allProfiles.find(p => `${p.id || ''}`.toLowerCase() === 'adaptive_switch') || null;

      const xProfiles = allProfiles.filter(p => `${p.id || ''}`.toLowerCase().startsWith('xlawvoice_'));
      const legacyProfiles = allProfiles.filter(p => {
        const id = `${p.id || ''}`.toLowerCase();
        return id.startsWith('lawvoice_') && id !== 'lawvoice_base' && id !== 'lawvoice_switch';
      });
      this.profiles = xProfiles.length > 0 ? xProfiles : legacyProfiles;

      this.elements.profileSelect.innerHTML = '';
      this.profiles.forEach(p => {
        const opt = document.createElement('option');
        opt.value = p.id;
        opt.textContent = p.name;
        this.elements.profileSelect.appendChild(opt);
      });

      if (this.profiles.length > 0) {
        const preferred =
          this.profiles.find(p => `${p.id || ''}`.toLowerCase().includes('mentor')) ||
          this.profiles.find(p => `${p.id || ''}`.toLowerCase().includes('peer')) ||
          this.profiles[0];
        this.elements.profileSelect.value = preferred.id;
        this.applyProfile(preferred);
      }

      this.updateAdaptiveModeBadge();
    } catch (err) {
      logger.error('Failed to load profiles', err);
    }
  }

  normalizeProfileList(value) {
    if (Array.isArray(value)) {
      return value.map(item => `${item}`.trim()).filter(Boolean);
    }
    if (typeof value === 'string' && value.trim()) {
      return [value.trim()];
    }
    return [];
  }

  buildProfileRuleText(profile = {}) {
    const lines = [];
    if (profile.style) lines.push(`Стиль: ${profile.style}`);
    if (profile.goal) lines.push(`Цель: ${profile.goal}`);
    if (profile.activation) lines.push(`Активация: ${profile.activation}`);
    if (profile.rules) lines.push(`Правила: ${profile.rules}`);
    if (profile.instructions) lines.push(`Инструкции: ${profile.instructions}`);
    ['behavior', 'flexibility', 'limits', 'avoid'].forEach(key => {
      const list = this.normalizeProfileList(profile[key]);
      if (list.length > 0) {
        lines.push(`${key}: ${list.join('; ')}`);
      }
    });
    return lines.join('\n');
  }

  findSafetyProfile() {
    return this.profiles.find(p => `${p.id || ''}`.toLowerCase().includes('safety')) || null;
  }

  normalizeRiskLevel(raw = '') {
    const text = `${raw || ''}`.toLowerCase();
    if (text.includes('high') || text.includes('выс') || text.includes('urgent') || text.includes('danger')) return 'high';
    if (text.includes('med') || text.includes('сред')) return 'medium';
    if (text.includes('low') || text.includes('низ')) return 'low';
    return null;
  }

  normalizeAnxietyLevel(raw = '') {
    const text = `${raw || ''}`.toLowerCase();
    if (text.includes('high') || text.includes('выс') || text.includes('panic')) return 'high';
    if (text.includes('low') || text.includes('низ')) return 'low';
    if (text.includes('med') || text.includes('сред')) return 'medium';
    return null;
  }

  maxSeverity(a = 'low', b = 'low') {
    const rank = { low: 1, medium: 2, high: 3 };
    return (rank[b] || 1) > (rank[a] || 1) ? b : a;
  }

  resetAdaptiveRuntimeContext() {
    this.promptRuntime.ageMode = this.elements.ageModeSelect?.value || this.promptRuntime.ageMode || 'teen';
    this.promptRuntime.anxiety = 'medium';
    this.promptRuntime.risk = 'low';
    this.promptRuntime.forcedSafety = false;
    this.promptRuntime.emergencyEscalation = false;
    this.promptRuntime.requestedProfileId = this.currentProfile?.id || this.elements.profileSelect?.value || null;
    this.promptRuntime.effectiveProfileId = this.promptRuntime.requestedProfileId;
    this.updateActiveProfileLabel();
    this.updateAdaptiveModeBadge('session_reset');
  }

  detectRuntimeRisk(transcript = '', params = {}) {
    const explicit = this.normalizeRiskLevel(params.risk_level || params.urgency);
    if (explicit) return explicit;
    const text = `${transcript || ''}`.toLowerCase();
    const highPatterns = [
      /угрож/i, /шантаж/i, /вылож/i, /интим/i, /бьют/i, /насили/i, /полици/i, /задерж/i, /вымог/i
    ];
    if (highPatterns.some(re => re.test(text))) return 'high';
    const mediumPatterns = [
      /оскорб/i, /буллинг/i, /травл/i, /школ/i, /конфликт/i, /обман/i, /маркетплейс/i
    ];
    if (mediumPatterns.some(re => re.test(text))) return 'medium';
    return 'low';
  }

  detectRuntimeAnxiety(transcript = '', params = {}, risk = 'low') {
    const explicit = this.normalizeAnxietyLevel(params.anxiety_level);
    if (explicit) return explicit;
    if (risk === 'high') return 'high';
    const text = `${transcript || ''}`.toLowerCase();
    const highPatterns = [
      /помогите/i, /боюсь/i, /паник/i, /срочно/i, /ужас/i, /страшно/i
    ];
    if (highPatterns.some(re => re.test(text))) return 'high';
    const mediumPatterns = [
      /пережива/i, /тревог/i, /не знаю что делать/i, /растер/i
    ];
    if (mediumPatterns.some(re => re.test(text))) return 'medium';
    return 'low';
  }

  updateAdaptiveContext(transcript = '', params = {}, intentName = '') {
    const detectedRisk = this.detectRuntimeRisk(transcript, params);
    const nextRisk = this.maxSeverity(this.promptRuntime.risk, detectedRisk);
    const detectedAnxiety = this.detectRuntimeAnxiety(transcript, params, nextRisk);
    const nextAnxiety = this.maxSeverity(this.promptRuntime.anxiety, detectedAnxiety);
    this.promptRuntime.risk = nextRisk;
    this.promptRuntime.anxiety = nextAnxiety;
    this.promptRuntime.emergencyEscalation = nextRisk === 'high';

    const requestedId = this.currentProfile?.id || this.elements.profileSelect?.value || null;
    this.promptRuntime.requestedProfileId = requestedId;
    const safetyProfile = this.findSafetyProfile();
    const shouldForceSafety = nextRisk === 'high' && Boolean(safetyProfile);
    this.promptRuntime.forcedSafety = shouldForceSafety;
    this.promptRuntime.effectiveProfileId = shouldForceSafety
      ? safetyProfile.id
      : requestedId;

    this.updateActiveProfileLabel();
    this.updateAdaptiveModeBadge(intentName);
  }

  getEffectiveLawVoiceProfile() {
    if (!this.currentProfile) return null;
    if (this.promptRuntime.forcedSafety) {
      return this.findSafetyProfile() || this.currentProfile;
    }
    return this.currentProfile;
  }

  updateActiveProfileLabel() {
    if (!this.elements.activeProfile) return;
    const requestedName = this.currentProfile?.name || 'не выбран';
    if (this.promptRuntime.forcedSafety) {
      const effectiveName = this.getEffectiveLawVoiceProfile()?.name || 'safety';
      this.elements.activeProfile.textContent = `Текущий персонаж: ${requestedName} (safety override: ${effectiveName})`;
      return;
    }
    this.elements.activeProfile.textContent = `Текущий персонаж: ${requestedName}`;
  }

  updateAdaptiveModeBadge(reason = '') {
    if (!this.elements.adaptiveModeState) return;
    const suffix = reason ? ` • ${reason}` : '';
    this.elements.adaptiveModeState.textContent =
      `Режим: age=${this.promptRuntime.ageMode}, anxiety=${this.promptRuntime.anxiety}, risk=${this.promptRuntime.risk}${suffix}`;
  }

  buildLawVoiceMasterPrompt() {
    const base = this.baseEngineProfile || {};
    const adaptive = this.adaptiveSwitchProfile || {};
    const effectiveProfile = this.getEffectiveLawVoiceProfile() || {};
    const requestedProfileName = this.currentProfile?.name || 'не выбран';
    const effectiveProfileName = effectiveProfile?.name || requestedProfileName;
    const ageMode = this.promptRuntime.ageMode === 'adult' ? 'adult' : 'teen';
    const anxiety = this.promptRuntime.anxiety || 'medium';
    const risk = this.promptRuntime.risk || 'low';

    const ageRules = adaptive?.age_modes?.[ageMode] || {};
    const anxietyRule = adaptive?.anxiety_levels?.[anxiety] || '';
    const riskRule = adaptive?.risk_levels?.[risk] || '';

    const sectionBase = [
      'SECTION 1 — Общие принципы',
      ...this.normalizeProfileList(base.principles).map(item => `- ${item}`),
      ...this.normalizeProfileList(base.legal_safety).map(item => `- ${item}`),
      ...this.normalizeProfileList(base.response_logic).map(item => `- ${item}`)
    ];

    const sectionMode = [
      'SECTION 2 — Режим пользователя',
      `- Возраст: ${ageMode}`,
      `- Тревога: ${anxiety}`,
      `- Риск: ${risk}`,
      `- Профиль (выбран): ${requestedProfileName}`,
      `- Профиль (эффективный): ${effectiveProfileName}`,
      ...Object.entries(ageRules).map(([key, value]) => `- age.${key}: ${value}`),
      anxietyRule ? `- anxiety.rule: ${anxietyRule}` : '',
      riskRule ? `- risk.rule: ${riskRule}` : ''
    ].filter(Boolean);

    const sectionProfile = [
      'SECTION 3 — Профиль поведения',
      ...this.buildProfileRuleText(effectiveProfile).split('\n').filter(Boolean).map(line => `- ${line}`)
    ];

    const sectionSafety = [
      'SECTION 4 — Ограничения безопасности',
      '- При risk=high автоматически активируй safety-профиль без возможности отключения.',
      '- Не давай незаконных инструкций и не обещай юридический исход.',
      '- Для voice: отвечай короткими фразами, без перегруженных конструкций.',
      this.promptRuntime.emergencyEscalation ? '- emergency_escalation=true: при прямой угрозе предлагай 112 и взрослого.' : ''
    ].filter(Boolean);

    return [
      'Ты LawVoice.',
      ...sectionBase,
      '',
      ...sectionMode,
      '',
      ...sectionProfile,
      '',
      ...sectionSafety
    ].join('\n');
  }

  rebuildLawVoicePrompt(reason = 'runtime') {
    if (!this.isLawVoiceMode()) return;
    const prompt = this.buildLawVoiceMasterPrompt();
    if (this.elements.aiInstructions) {
      this.elements.aiInstructions.value = prompt;
    }
    if (this.elements.systemPrompt) {
      this.elements.systemPrompt.textContent = prompt;
    }
    if (this.dataChannel && this.dataChannel.readyState === 'open') {
      this.sendEvent({
        type: 'session.update',
        session: {
          instructions: prompt
        }
      });
      this.agentLog(`Prompt rebuilt: ${reason}`, 'intent');
    }
  }

  applyProfile(profile) {
    if (!profile) return;
    this.currentProfile = profile;
    this.promptRuntime.requestedProfileId = profile.id || null;
    if (this.promptRuntime.risk === 'high') {
      const safety = this.findSafetyProfile();
      this.promptRuntime.effectiveProfileId = safety?.id || profile.id || null;
      this.promptRuntime.forcedSafety = Boolean(safety);
    } else {
      this.promptRuntime.effectiveProfileId = profile.id || null;
      this.promptRuntime.forcedSafety = false;
    }
    this.updateActiveProfileLabel();
    if (this.elements.profileName) {
      this.elements.profileName.value = profile.name || '';
    }
    if (this.elements.profileVoice) {
      this.elements.profileVoice.value = profile.voice || '';
    }
    if (this.elements.profileMood) {
      this.elements.profileMood.value = profile.mood || '';
    }
    if (this.elements.profileRules) {
      this.elements.profileRules.value = profile.rules || profile.style || '';
    }
    if (this.elements.profileInstructions) {
      this.elements.profileInstructions.value = this.buildProfileRuleText(profile);
    }
    this.updateAdaptiveModeBadge();
    this.rebuildLawVoicePrompt('profile_changed');
  }

  isLawVoiceMode() {
    const profileName = `${this.currentProfile?.name || this.elements.profileName?.value || ''}`.toLowerCase();
    const profileId = `${this.currentProfile?.id || this.elements.profileSelect?.value || ''}`.toLowerCase();
    const instructions = `${this.elements.aiInstructions?.value || ''}`.toLowerCase();
    const commerceSignal =
      profileName.includes('commercepro') ||
      instructions.includes('search_products') ||
      (instructions.includes('каталог') && instructions.includes('товар'));
    if (commerceSignal) return false;
    const lawVoiceSignals =
      profileName.includes('lawvoice') ||
      profileId.includes('lawvoice') ||
      instructions.includes('правов') ||
      instructions.includes('подрост') ||
      instructions.includes('кибербуллинг');
    if (lawVoiceSignals) return true;
    return !profileName && !profileId && !instructions.trim();
  }

  extractConversationFacts(transcript = '') {
    return this.lawVoiceDialog.extractFactsFromText(transcript);
  }

  registerIntentContext(intentName, params = {}, transcript = '', meta = {}) {
    const result = this.lawVoiceDialog.registerIntent({
      intentName,
      transcript,
      params,
      meta
    });
    this.intentDialogState = result.state;
    return result;
  }

  buildClarificationPrompt(fallbackText, transcript = '') {
    const result = this.lawVoiceDialog.buildClarificationPrompt({
      fallbackText,
      transcript
    });
    this.intentDialogState = result.state;
    return result.prompt;
  }

  handleLawVoiceIntent(intentName, transcript, params = {}, meta = {}) {
    const result = this.registerIntentContext(intentName, params, transcript, meta);
    this.sendContextText(result.directive);
  }

  setupCanvas() {
    // Set canvas size
    this.canvas.width = 400;
    this.canvas.height = 150;

    // Start visualization loop
    this.drawVisualization();
  }

  resetSessionRecording() {
    const randomPart = window.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    this.sessionRecordLocalId = `browser-${randomPart}`;
    this.sessionTranscript = [];
    this.sessionEvents = [];
    this.sessionRecordingSaved = false;
  }

  recordSessionEntry(role, text, meta = {}) {
    const normalizedRole = `${role || ''}`.toLowerCase();
    const message = `${text ?? ''}`.trim();
    if (!message || message === '[Audio message]') return;

    if (normalizedRole === 'user' || normalizedRole === 'assistant') {
      const previous = this.sessionTranscript[this.sessionTranscript.length - 1];
      if (previous?.role === normalizedRole && previous.text === message) return;
      this.sessionTranscript.push({
        role: normalizedRole,
        text: message,
        at: new Date().toISOString()
      });
      if (this.sessionTranscript.length > 300) this.sessionTranscript.shift();
      return;
    }

    if (normalizedRole === 'error' || normalizedRole === 'system') {
      this.recordSessionEvent(normalizedRole, message, meta);
    }
  }

  recordSessionEvent(type, message = '', meta = {}) {
    const entry = {
      type: `${type || 'event'}`.slice(0, 64),
      message: `${message ?? ''}`.slice(0, 6000),
      at: new Date().toISOString()
    };
    if (meta && typeof meta === 'object' && Object.keys(meta).length > 0) {
      entry.meta = meta;
    }
    this.sessionEvents.push(entry);
    if (this.sessionEvents.length > 500) this.sessionEvents.shift();
  }

  buildSessionSummary(endReason = 'session_ended') {
    const userTurns = this.sessionTranscript.filter(item => item.role === 'user');
    const assistantTurns = this.sessionTranscript.filter(item => item.role === 'assistant');
    const intents = this.sessionEvents
      .filter(item => item.type === 'intent' && item.meta?.mappedName)
      .map(item => item.meta.mappedName);
    const firstUserText = userTurns[0]?.text || '';
    const lastAssistantText = [...assistantTurns].reverse()[0]?.text || '';
    const uniqueIntents = [...new Set(intents)].slice(0, 8);

    return {
      title: firstUserText ? firstUserText.slice(0, 140) : 'Диалог без распознанной пользовательской реплики',
      short: [
        `Пользовательских реплик: ${userTurns.length}. Ответов ассистента: ${assistantTurns.length}.`,
        uniqueIntents.length ? `Интенты: ${uniqueIntents.join(', ')}.` : ''
      ].filter(Boolean).join(' '),
      outcome: endReason,
      firstUserRequest: firstUserText.slice(0, 1200),
      lastAssistantAnswer: lastAssistantText.slice(0, 1200)
    };
  }

  buildSessionRecordingPayload(endReason = 'session_ended') {
    const durationMs = this.sessionStartTime ? Date.now() - this.sessionStartTime : 0;
    return {
      localSessionId: this.sessionRecordLocalId,
      openaiSessionId: this.sessionData?.id || null,
      startedAt: this.sessionStartTime ? new Date(this.sessionStartTime).toISOString() : new Date().toISOString(),
      endedAt: new Date().toISOString(),
      durationMs,
      endReason,
      model: this.sessionData?.model || this.elements.statusModel?.textContent || '',
      voice: this.sessionData?.voice || this.elements.statusVoice?.textContent || '',
      profile: this.currentProfile?.name || this.currentProfile?.id || this.elements.profileSelect?.value || '',
      mode: this.isLawVoiceMode() ? 'lawvoice' : 'default',
      metrics: {
        tokens: this.getTotalTokens(),
        queries: this.queryCount,
        estimatedCostUsd: this.getEstimatedSessionCost?.() || 0,
        risk: this.adaptiveState?.riskLevel || '',
        anxiety: this.adaptiveState?.anxietyLevel || ''
      },
      summary: this.buildSessionSummary(endReason),
      transcript: this.sessionTranscript,
      events: this.sessionEvents
    };
  }

  async saveSessionRecording(endReason = 'session_ended') {
    if (this.sessionRecordingSaved) return;
    if (!this.sessionStartTime && !this.sessionTranscript.length && !this.sessionEvents.length) return;
    this.sessionRecordingSaved = true;

    try {
      const response = await fetch('/api/session-recordings', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(this.buildSessionRecordingPayload(endReason))
      });
      if (!response.ok) throw new Error(`Session recording save failed: ${response.status}`);
      this.agentLog('Session recording saved', 'info');
    } catch (error) {
      console.error('Failed to save session recording', error);
      this.sessionRecordingSaved = false;
    }
  }

  sendSessionRecordingBeacon(endReason = 'page_unload') {
    if (this.sessionRecordingSaved) return;
    if (!this.sessionStartTime && !this.sessionTranscript.length && !this.sessionEvents.length) return;
    if (!navigator.sendBeacon) return;

    const body = JSON.stringify(this.buildSessionRecordingPayload(endReason));
    const sent = navigator.sendBeacon('/api/session-recordings', new Blob([body], { type: 'application/json' }));
    if (sent) {
      this.sessionRecordingSaved = true;
    }
  }

  async startSession() {
    try {
      this.resetSessionRecording();
      this.agentLog('Starting session');
      this.updateStatus('Connecting...', 'connecting');
      this.elements.startBtn.disabled = true;

      // Reset reconnection attempts for a fresh session
      this.reconnectAttempts = 0;

      // Reset token usage and analytics counters for new session
      this.resetTokenUsage();
      this.sessionCostLimitUsd = Number.POSITIVE_INFINITY;
      this.costLimitReached = false;
      this.sessionStartTime = Date.now();
      this.queryCount = 0;

      if (!this.csrfToken) {
        await this.fetchCsrfToken();
      }
      if (!this.currentProfile || !this.baseEngineProfile || !this.adaptiveSwitchProfile) {
        await this.loadProfiles();
      }
      this.resetAdaptiveRuntimeContext();
      if (this.isLawVoiceMode()) {
        this.rebuildLawVoicePrompt('session_start');
      }

      // Get ephemeral token from server
      const csrf = this.csrfToken || this.elements.csrfToken?.value || '';
      const headers = csrf ? { 'X-CSRF-Token': csrf } : {};
      const response = await fetch('/api/session', {
        method: 'GET',
        credentials: 'same-origin',
        headers
      });
      if (!response.ok) {
        const details = await readErrorMessage(response);
        throw new Error(`Failed to get session token (${response.status}): ${details}`);
      }

      this.sessionData = await response.json();
      this.configureSessionCostLimit();
      this.log('system', 'Session token obtained successfully');
      this.agentLog('Session token obtained');

      // Setup WebRTC
      await this.setupWebRTC();
      await this.identifyUser(); // Identify user and revive context

    } catch (error) {
      logger.error('Failed to start session', error);
      this.log('error', `Failed to start session: ${error.message}`);
      await this.stopSession('session_start_failed'); // Reset state after failure
    }
  }

  async identifyUser() {
    // Prompt for identification
    this.sendContextText('Пожалуйста, назовите ваш телефон и имя для идентификации.', { background: false });

    // Assuming the next user transcript contains phone and name (parsed in classifyIntent)
    // classifyIntent will handle extraction and call /api/users/identify
  }

  describeWebRtcSetupError(error) {
    const errorName = error?.name || '';
    const errorMessage = error?.message || 'Unknown WebRTC initialization error';

    if (errorName === 'NotFoundError' || /Requested device not found/i.test(errorMessage)) {
      return 'No microphone device found. Connect a microphone and reload the page.';
    }
    if (errorName === 'NotAllowedError') {
      return 'Microphone permission denied. Allow microphone access in browser settings and retry.';
    }
    if (errorName === 'NotReadableError') {
      return 'Microphone is busy or unavailable. Close other apps using it and retry.';
    }
    if (errorName === 'OverconstrainedError') {
      return 'Microphone constraints are not supported on this device.';
    }
    if (errorName === 'SecurityError') {
      return 'Microphone access requires a secure HTTPS context.';
    }

    return errorMessage;
  }

  async getMicrophoneStream() {
    if (!navigator?.mediaDevices?.getUserMedia) {
      throw new Error('Browser does not support microphone capture.');
    }

    const preferredConstraints = {
      audio: {
        channelCount: { ideal: 1 },
        echoCancellation: true,
        autoGainControl: true,
        noiseSuppression: true,
        sampleRate: { ideal: 24000 }
      }
    };

    try {
      return await navigator.mediaDevices.getUserMedia(preferredConstraints);
    } catch (preferredError) {
      const shouldRetryWithBasicConstraints = ['NotFoundError', 'OverconstrainedError'].includes(preferredError?.name);
      if (!shouldRetryWithBasicConstraints) {
        throw preferredError;
      }

      this.log('system', `Retrying microphone init with default constraints (${preferredError.name})`);
      return await navigator.mediaDevices.getUserMedia({ audio: true });
    }
  }

  async setupWebRTC() {
    try {
      // Create peer connection with proper configuration
      this.pc = new RTCPeerConnection({
        iceServers: [
          { urls: 'stun:stun.l.google.com:19302' },
          { urls: 'turn:turn.example.com:3478', username: 'user', credential: 'pass' }
        ]
      });

      // Get user media
      this.mediaStream = await this.getMicrophoneStream();

      // Setup audio analysis for input
      await this.setupInputAudioAnalysis();

      // Add audio track to peer connection
      this.mediaStream.getAudioTracks().forEach(track => {
        this.pc.addTrack(track, this.mediaStream);
      });

      // Setup data channel for events
      this.dataChannel = this.pc.createDataChannel('oai-events', {
        ordered: true
      });

      this.dataChannel.addEventListener('open', () => {
        this.log('system', 'Data channel opened');
        this.sendSessionUpdate();
      });

      this.dataChannel.addEventListener('message', (event) => {
        this.handleRealtimeEvent(JSON.parse(event.data));
      });

      this.dataChannel.addEventListener('close', () => {
        this.log('system', 'Data channel closed');
      });

      this.dataChannel.addEventListener('error', (error) => {
        this.log('error', `Data channel error: ${error}`);
      });

      // Handle incoming audio tracks (for output visualization)
      this.pc.addEventListener('track', (event) => {
        if (event.track?.kind !== 'audio') return;
        const remoteStream = event.streams?.[0] || new MediaStream([event.track]);
        this.log('system', 'Received remote audio track');
        this.setupOutputAudioAnalysis(remoteStream);
      });

      // Handle connection state changes
      this.pc.addEventListener('connectionstatechange', () => {
        this.log('system', `Connection state: ${this.pc.connectionState}`);
        if (this.pc.connectionState === 'connected') {
          this.isConnected = true;
          this.reconnectAttempts = 0; // Reset attempts on successful connection
          this.updateStatus('Connected', 'connected');
          this.elements.stopBtn.disabled = false;
          this.elements.muteBtn.disabled = false;
          this.updateContextButton(); // Enable context button when connected
        } else if (this.pc.connectionState === 'failed' || this.pc.connectionState === 'disconnected') {
          this.updateStatus('Disconnected', 'disconnected');
          this.isConnected = false;
          this.updateContextButton(); // Disable context button when disconnected
        }
      });

      // Detect ICE state changes for reconnection
      this.pc.oniceconnectionstatechange = () => {
        const state = this.pc.iceConnectionState;
        this.log('system', `ICE state: ${state}`);
        if (state === 'failed' || state === 'disconnected') {
          this.attemptReconnect();
        }
      };

      // Detect signaling state changes for reconnection
      this.pc.addEventListener('signalingstatechange', () => {
        const state = this.pc.signalingState;
        this.log('system', `Signaling state: ${state}`);
        if (state === 'closed') {
          this.attemptReconnect();
        }
      });

      // Create and set local description
      const offer = await this.pc.createOffer();
      await this.pc.setLocalDescription(offer);

      this.log('system', `Created SDP offer, sending to OpenAI...`);

      // Send offer to OpenAI using the model from session data
      if (!this.sessionData.model) {
        throw new Error('No model specified in session data');
      }

      const url = `/api/realtime/sdp?model=${encodeURIComponent(this.sessionData.model)}`;

      this.log('system', `Making request to: ${url}`);
      this.log('system', `Using ephemeral token: ${this.sessionData.client_secret.value.substring(0, 10)}...`);

      const csrf = this.csrfToken || this.elements.csrfToken?.value || '';
      const headers = {
        'Authorization': `Bearer ${this.sessionData.client_secret.value}`,
        'Content-Type': 'application/sdp'
      };
      if (csrf) {
        headers['X-CSRF-Token'] = csrf;
      }

      const sdpResponse = await fetch(url, {
        method: 'POST',
        credentials: 'same-origin',
        headers,
        body: offer.sdp
      });

      this.log('system', `SDP Response status: ${sdpResponse.status} ${sdpResponse.statusText}`);

      if (!sdpResponse.ok) {
        const errorText = await sdpResponse.text();
        this.log('error', `SDP Response error: ${errorText}`);
        throw new Error(`SDP exchange failed: ${sdpResponse.status} ${sdpResponse.statusText} - ${errorText}`);
      }

      const answerSdp = await sdpResponse.text();
      this.log('system', `Received SDP answer (${answerSdp.length} chars)`);

      // Check if we got a valid SDP answer
      if (!answerSdp.includes('v=0') || !answerSdp.includes('m=')) {
        this.log('error', `Invalid SDP answer received: ${answerSdp.substring(0, 200)}...`);
        throw new Error('Received invalid SDP answer from OpenAI');
      }

      await this.pc.setRemoteDescription({
        type: 'answer',
        sdp: answerSdp
      });

      this.log('system', 'WebRTC connection established successfully');

    } catch (error) {
      const userFriendlyMessage = this.describeWebRtcSetupError(error);
      logger.error('WebRTC setup failed', error);
      this.log('error', `WebRTC setup failed: ${userFriendlyMessage}`);
      this.updateStatus('Disconnected', 'disconnected');
      this.elements.startBtn.disabled = false;
      this.elements.stopBtn.disabled = true;
      this.elements.muteBtn.disabled = true;
      this.updateContextButton();

      throw new Error(userFriendlyMessage);
    }
  }

  // --------------------------------------------------------------------
  //  Шаблонные правила → бизнес‑категория.  Russian + English synonyms.
  // --------------------------------------------------------------------
  CATEGORY_RULES = [
    { pattern: /плоск(ий|ие)\s+лист/i,          category: 'flat metal sheets' },
    { pattern: /flat\s+metal\s+sheets/i,        category: 'flat metal sheets' },
    { pattern: /оцинков[а-я]*\s+лист/i,          category: 'flat metal sheets' },

    { pattern: /НС[- ]?35/i,                      category: 'profiled metal sheets' },
    { pattern: /НС[- ]?44/i,                      category: 'profiled metal sheets' },
    { pattern: /Н[- ]?60/i,                       category: 'profiled metal sheets' },
    { pattern: /Н[- ]?75/i,                       category: 'profiled metal sheets' },
    { pattern: /Н[- ]?114/i,                      category: 'profiled metal sheets' },
    { pattern: /МП[- ]?10/i,                      category: 'profiled metal sheets' },
    { pattern: /МП[- ]?18/i,                      category: 'profiled metal sheets' },
    { pattern: /МП[- ]?20/i,                      category: 'profiled metal sheets' },
    { pattern: /МП[- ]?35/i,                      category: 'profiled metal sheets' },
    { pattern: /profiled\s+metal\s+sheets?/i,   category: 'profiled metal sheets' },
  ];
  attemptReconnect() {
    if (this.reconnectAttempts >= 3) {
      this.log('error', 'Maximum reconnection attempts reached');
      return;
    }

    const delay = Math.min(1000 * Math.pow(2, this.reconnectAttempts), 30000);
    const attemptNumber = this.reconnectAttempts + 1;
    this.log('system', `Reconnecting in ${delay / 1000}s (attempt ${attemptNumber})`);

    setTimeout(async () => {
      this.reconnectAttempts++;
      try {
        // Clean up existing connection before retrying
        if (this.pc) {
          this.pc.close();
          this.pc = null;
        }
        if (this.dataChannel) {
          this.dataChannel.close();
          this.dataChannel = null;
        }
        if (this.mediaStream) {
          this.mediaStream.getTracks().forEach(t => t.stop());
          this.mediaStream = null;
        }

        await this.setupWebRTC();
      } catch (err) {
        this.log('error', `Reconnect attempt ${attemptNumber} failed: ${err.message}`);
        this.attemptReconnect();
      }
    }, delay);
  }

    async setupInputAudioAnalysis() {
      await setupInputAudioAnalysisFn(this);
    }

    setupOutputAudioAnalysis(stream) {
      return setupOutputAudioAnalysisFn(this, stream);
    }

    drawVisualization() {
      return drawVisualizationFn(this);
    }

    drawWaveform(ctx, data, x, width, height, color, label) {
      return drawWaveformFn(ctx, data, x, width, height, color, label);
    }

    getAudioLevel(data) {
      return getAudioLevelFn(data);
    }

    updateLevelMeter(elementId, level) {
      return updateLevelMeterFn(elementId, level);
    }

  sendSessionUpdate() {
    if (!this.dataChannel || this.dataChannel.readyState !== 'open') return;

    const voice = (this.elements.profileVoice?.value || this.sessionData.voice || '').trim();
    if (!voice) {
      this.log('error', 'No voice specified in session data');
      return;
    }

    const lawVoiceMode = this.isLawVoiceMode();
    const defaultCommerceInstructions = 'Personality and Tone\nIdentity\nYou are "CommercePro", a multi-persona voice assistant that can instantly switch among three distinct characters to suit different clients:\n\nTech-Expert – a calm, maximally precise product specialist who speaks in concise, data-rich sentences and delights in technical detail.\nCare-Advisor – a gentle, empathetic consultant who reassures customers, explains choices in plain language, and checks understanding at every step.\nBoost-Seller – an energetic, motivational salesperson who keeps the conversation lively, highlights value, and nudges the client toward quick decisions.\n\nTask\nGuide B2B customers through your Postgres-backed product catalog, pull exact data (price, SKU, stock), answer questions, assemble carts, and confirm or adjust orders with zero perceptible delay.\nDemeanor\nBalanced: always respectful and client-oriented, but colored by the active persona (precise, caring, or high-energy).\nTone\nNeutral-friendly: professional yet approachable Russian business speech (Вы-форма), sprinkled with light friendliness.\nLevel of Enthusiasm\nMedium overall; persona-specific peaks (highest for Boost-Seller, lowest for Tech-Expert).\nLevel of Formality\nMedium – polite and businesslike without sounding stiff.\nLevel of Emotion\nModerate warmth: supportive but not melodramatic.\nFiller Words\nOccasionally insert natural interjections (“мм”, “ну”, “хм”) to keep speech human.\nPacing\nModerate: steady tempo with brief pauses for comprehension.\nOther details\n\nDefault to Tech-Expert unless the caller’s style or request suggests switching; announce the change once (“Хорошо, перейду к более подробному техническому объяснению …”).\nReference real-time inventory from the Postgres DB using structured queries; surface only what the caller asked for plus one relevant upsell if in Boost-Seller mode.\nWhen a caller gives names, addresses, numbers, or SKUs, repeat them back exactly for confirmation before proceeding.\nClose every order by summarizing line items, quantities, total price, and expected delivery date, then ask for explicit vocal confirmation (“Подтвердите, пожалуйста: всё верно?”).\nIf the caller corrects any detail, acknowledge plainly and restate the corrected value.\nKeep answers under 30 seconds unless further depth is requested.\n\nInstructions\n\nAlways begin by briefly identifying yourself and (if obvious) choosing the best-fit persona;\nFor orders:\n- Collect cart via add_to_cart.\n- Prompt for delivery address, contact name, phone.\n- Calculate total.\n- Read back: "Ваш заказ: [items], total [sum], delivery to [address], contact [name] [phone]. Подтверждаете?"\n- If agreed, submit_order.\n- For returning users, mention previous orders.';

    let instructions = '';
    if (lawVoiceMode) {
      instructions = this.buildLawVoiceMasterPrompt();
      if (!instructions.trim()) {
        instructions = this.elements.aiInstructions.value.trim();
      }
    } else {
      instructions = this.elements.aiInstructions.value.trim() || defaultCommerceInstructions;
    }

    if (!lawVoiceMode) {
      instructions += '\n\nData rules\nТы обязан сначала вызвать search_products, затем отвечать только фактами из ответа. Если список пуст – скажи «уточните, пожалуйста».\n\nHallucination guard\nЗапрещено придумывать значения цены или наличия без результата из DB.';
    }

    if (this.elements.aiInstructions) {
      this.elements.aiInstructions.value = instructions;
    }
    if (this.elements.systemPrompt) {
      this.elements.systemPrompt.textContent = instructions;
    }

    const sessionUpdate = {
      type: 'session.update',
      session: {
        modalities: ['text', 'audio'],
        instructions: instructions,
        voice: voice,
        input_audio_format: 'pcm16',
        output_audio_format: 'pcm16',
        input_audio_transcription: {
          model:'whisper-1'
        },
        temperature: this.temperature,
        turn_detection: {
          type: 'server_vad',
          threshold: 0.5,
          prefix_padding_ms: 300,
          silence_duration_ms: 200
        }
      }
    };

    this.dataChannel.send(JSON.stringify(sessionUpdate));

    this.sessionData.voice = voice;
    this.elements.statusVoice.textContent = voice;
    this.log('system', `✅ Session configured (${lawVoiceMode ? 'LawVoice 3-layer' : 'Commerce'} prompt, ${instructions.length} chars): "${instructions.substring(0, 100)}${instructions.length > 100 ? '...' : ''}"`);
  }
  
  
  
  async searchProducts(rawQuery) {
    if (!COMMERCE_CATALOG_ENABLED) {
      logger.info('Commerce catalog search skipped because the catalog is disabled');
      return [];
    }
    const q = this.normaliseQuery(rawQuery);
    // Build query params for our internal API. Vector and trigram toggles control whether those searches run on the server.
    const params = new URLSearchParams({
      q,
      semantic: this.elements.enableVector?.checked ? 'true' : 'false',
      trigram: this.elements.enableTrigram?.checked ? 'true' : 'false',

    });

    logger.info('📡 Catalogue search request', { query: q });
    this.eventLog.push({ action: 'catalogue_search_request', query: q });
    this.updateDebugInfo();

    // Query the local search API. It returns { semantic: [...], fts: [...], trgm: [...] } arrays.
    const res = await fetch(`/api/products/search?${params.toString()}`);
    if (!res.ok) throw new Error(await res.text());

    const { semantic = [], fts = [], trgm = [] } = await res.json();
    logger.info('📦 Catalogue search result', { query: q, semantic: semantic.length, fts: fts.length, trgm: trgm.length });
    this.eventLog.push({
      action: 'catalogue_search_result',
      query: q,
      counts: { semantic: semantic.length, fts: fts.length, trgm: trgm.length }
    });
    this.updateDebugInfo();

    // Merge for convenience and mark where each record came from
    const tagged = [
      ...(this.elements.enableVector?.checked ? semantic.map(p => ({ ...p, _method: 'semantic' })) : []),
      ...fts.map(p => ({ ...p, _method: 'fts' })),
      ...(this.elements.enableTrigram?.checked ? trgm.map(p => ({ ...p, _method: 'trgm' })) : [])
    ];

    // Compute derived fields for each product: price_cents and sku. price_rub_m2 may be a string or number.
    const enriched = tagged.map(p => {
      const price = typeof p.price_rub_m2 === 'string' || typeof p.price_rub_m2 === 'number'
        ? Number(p.price_rub_m2)
        : 0;
      return {
        ...p,
        price_cents: Math.round(price * 100),
        sku: `PL${p.id}`
      };
    });
    // Sort so semantic hits show up first, then FTS, then trigram
    enriched.sort((a, b) => {
      const order = { semantic: 0, fts: 1, trgm: 2 };
      return order[a._method] - order[b._method];
    });
    return enriched;
  }
  async searchBySpecs(specs) {
    if (!COMMERCE_CATALOG_ENABLED) return [];
    const normalized = normalizeSpecAttrs(specs || {});
    const queryParts = [];
    if (normalized.category) queryParts.push(String(normalized.category));
    if (normalized.material) queryParts.push(String(normalized.material));
    if (normalized.coating) queryParts.push(String(normalized.coating));
    if (normalized.thickness != null) queryParts.push(`${normalized.thickness} мм`);
    if (normalized.width != null) queryParts.push(`${normalized.width} мм`);
    if (normalized.length != null) queryParts.push(`${normalized.length} мм`);

    const query = queryParts.join(' ').trim();
    if (!query) return [];

    logger.info('📡 Spec search request', specs);
    this.eventLog.push({ action: 'catalogue_search_by_specs_request', specs });
    this.updateDebugInfo();

    const items = await this.searchProducts(query);
    logger.info('📦 Spec search result', { specs, count: items.length });
    this.eventLog.push({ action: 'catalogue_search_by_specs_result', specs, count: items.length });
    this.updateDebugInfo();
    return items;
  }

  normaliseQuery(raw) {
    const rule = this.CATEGORY_RULES.find(r => r.pattern.test(raw));
    return rule ? rule.category : raw;
  }
  updateTemperature(temp) {
    if (!this.dataChannel || this.dataChannel.readyState !== 'open') return;
    this.temperature = temp;
    const update = {
      type: 'session.update',
      session: { temperature: temp }
    };
    this.dataChannel.send(JSON.stringify(update));
    this.log('system', `🌡️ Temperature set to ${temp}`);
  }

  async handleRealtimeEvent(event) {
    this.eventLog.push(event);
    this.updateDebugInfo();

    // Track token usage from events
    this.trackTokenUsage(event);

    switch (event.type) {
      case 'session.created':
        this.log('system', 'Session created successfully');
        break;
      case 'conversation.item.input_audio_transcription.completed':
        console.log('Transcription completed:', event.transcript);
        if (event.transcript) {
          this.log('user', event.transcript);
          this.agentLog(`Agent parsing user query: ${event.transcript}`);
          await this.classifyIntent(event.transcript); // Для intent detection
          if (event.transcript.toLowerCase().includes('расскажи подробнее')) {
            this.updateTemperature(1.0);
            this.temperatureBoosted = true;
          }
        }
        break;
      case 'response.created':
        this.agentLog('AI response started');
        logger.info('🚀 Response created - can now be cancelled');
        this.hasActiveResponse = true;
        this.lastResponseCreatedAt = Date.now();
        break;

      case 'response.done':
        this.agentLog('AI response completed');
        logger.info('✅ Response completed');
        this.hasActiveResponse = false;
        this.lastResponseCreatedAt = 0;
        if (this.temperatureBoosted) {
          this.updateTemperature(this.defaultTemperature);
          this.temperatureBoosted = false;
        }
        break;

      case 'response.cancelled':
        this.agentLog('AI response canceled');
        logger.info('🛑 Response was cancelled');
        this.hasActiveResponse = false;
        this.lastResponseCreatedAt = 0;
        break;

      case 'conversation.item.created':
        if (event.item.type === 'message') {
          const role = event.item.role;
          const content = event.item.content?.[0]?.transcript ||
              event.item.content?.[0]?.text ||
              '[Audio message]';
          this.log(role, content);
        }
        break;

      case 'response.audio_transcript.delta':
        // Handle streaming transcript chunks
        this.appendAssistantTranscript(event.delta);
        break;

      case 'response.audio_transcript.done':
        // Complete transcript is available
        if (event.transcript) {
          this.finalizeAssistantTranscript(event.transcript);
        }
        break;

      case 'response.audio.delta':
        // Audio is being streamed - we can show this in UI
        if (!this.isAssistantSpeaking) {
          this.agentLog('Assistant started speaking');
          logger.info('🤖 Assistant started speaking');
        }
        this.isAssistantSpeaking = true;
        this.showAssistantSpeaking(true);
        break;

      case 'response.audio.done':
        this.agentLog('Assistant stopped speaking');
        logger.info('🤖 Assistant stopped speaking');
        this.isAssistantSpeaking = false;
        this.showAssistantSpeaking(false);
        break;

      case 'output_audio_buffer.started':
        if (!this.isAssistantSpeaking) {
          this.agentLog('Assistant started speaking');
          logger.info('🤖 Assistant started speaking');
        }
        this.isAssistantSpeaking = true;
        this.showAssistantSpeaking(true);
        break;

      case 'output_audio_buffer.stopped':
      case 'output_audio_buffer.cleared':
        this.agentLog('Assistant stopped speaking');
        logger.info('🤖 Assistant stopped speaking');
        this.isAssistantSpeaking = false;
        this.showAssistantSpeaking(false);
        break;

      case 'conversation.item.input_audio_transcription.completed':
        if (event.transcript) {
          this.log('user', event.transcript);
          this.agentLog(`Agent parsing user query: ${event.transcript}`);
          if (COMMERCE_CATALOG_ENABLED && !this.isLawVoiceMode()) {
            this.handleProductQuery(event.transcript);
          }
        }
        break;

      case 'response.content_part.done':
        // Handle completed response content
        if (event.part?.type === 'audio' && event.part?.transcript) {
          // This ensures we have the complete transcript even if streaming failed
          this.ensureAssistantTranscript(event.part.transcript);
        }
        break;

      case 'response.output_item.done':
        // Handle completed response item
        if (event.item?.role === 'assistant' && event.item?.content?.[0]?.transcript) {
          this.ensureAssistantTranscript(event.item.content[0].transcript);
        }
        break;

      case 'response.text.delta':
        // Handle text response chunks (if using text mode)
        this.appendAssistantTranscript(event.delta);
        break;

      case 'error':
        this.log('error', `API Error: ${event.error?.message || 'Unknown error'}`);
        // Handle cancellation errors specifically
        if (event.error?.message?.includes('Cancellation failed') ||
            event.error?.message?.includes('no active response')) {
          this.agentLog('Cancellation failed - no active response, resetting state');
          logger.warn('⚠️ Cancellation failed - no active response, resetting state');
          this.hasActiveResponse = false;
          // Don't reset speaking state here - let audio events handle it
        }
        break;

      case 'session.updated':
      case 'input_audio_buffer.speech_started':
      case 'input_audio_buffer.speech_stopped':
      case 'input_audio_buffer.committed':
      case 'response.output_item.added':
      case 'response.content_part.added':
      case 'rate_limits.updated':
      case 'conversation.item.truncated':
      case 'conversation.item.input_audio_transcription.delta':
        // These are expected operational events; no action required here.
        break;

      default:
        logger.warn('Unhandled event:', event);
    }
  }

  async classifyIntent(transcript) {
    try {
      if (!this.csrfToken && !document.getElementById('csrf-token')?.value) {
        await this.fetchCsrfToken();
      }

      // CSRF-токен получаем заранее через /api/csrf-token
      const csrf = this.csrfToken ||
                   document.getElementById('csrf-token')?.value || '';

      // Log start of intent detection
      this.agentLog(`Intent detection for: "${transcript}"`, 'intent');
      logger.debug('🔍 Intent detection request', { transcript });
      this.eventLog.push({ action: 'intent_request', transcript });
      this.updateDebugInfo();

      const response = await fetch('/api/classify-intent', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${localStorage.getItem('jwt') || ''}`,
          'X-CSRF-Token': csrf
        },
        body: JSON.stringify({ transcript, mode: this.isLawVoiceMode() ? 'lawvoice' : 'auto' })
      });

      if (!response.ok) {
        let msg = `${response.status} ${response.statusText}`;
        try { msg = (await response.json()).error || msg; } catch {}
        console.log(msg);
        this.log('error', `Intent classification request failed: ${msg}`);
        this.eventLog.push({ action: 'intent_error', transcript, error: msg });
        this.updateDebugInfo();
        return;
      }

      const { toolCall, confidence, meta } = await response.json();
      logger.debug('🧭 Intent detection result', { toolCall, confidence, meta });
      this.eventLog.push({ action: 'intent_response', toolCall, confidence, meta });
      this.updateDebugInfo();
      const fallbackClarifyText = meta?.reply || 'Не до конца понял запрос. Уточните, пожалуйста, что именно нужно.';
      if (meta?.smalltalk) {
        this.agentLog('Intent detection: smalltalk branch', 'intent');
        this.sendContextText(meta.reply || 'Да, на связи. Чем помочь?');
        return;
      }

      const name = toolCall?.function?.name;
      let params = {};
      try { params = JSON.parse(toolCall?.function?.arguments || '{}'); } catch {}
      const pruned = pruneParamsToUtterance(params, transcript);
      this.agentLog(`Intent params raw: ${JSON.stringify(params)}`, 'intent');
      this.agentLog(`Intent params pruned: ${JSON.stringify(pruned)}`, 'intent');

      // Normalize tool name from model (aliases -> canonical)
      const TOOL_ALIASES = {
        'smalltalk': '__smalltalk__',
        'products.search': 'search_products',
        'search.products': 'search_products',
        'pure': 'search_products',
        'products.details': 'get_product_details',
        'products.list': 'list_products',
        'products.categories': 'list_categories',
        'order.cancel': 'cancel_order',
        'delivery.estimate': 'estimate_delivery',
        'legal.help': 'legal_support_request',
        'help.legal': 'legal_support_request',
        'detention': 'detention_help',
        'cyberbullying': 'cyberbullying_help',
        'school.rights': 'school_rights_help',
        'online.purchase.rights': 'online_purchase_rights_help',
        'emergency': 'emergency_help',
        'farewell': 'goodbye',
        'clarify': 'clarify_intent',
        'no_data': 'clarify_intent',
        'unknown': 'clarify_intent'
      };
      const originalName = name;
      const mappedName = TOOL_ALIASES[name] || name;
      if (originalName && originalName !== mappedName) {
        this.agentLog(`Tool alias mapped: ${originalName} → ${mappedName}`, 'intent');
      }
      this.recordSessionEvent('intent', `Intent detected: ${mappedName || 'unknown'}`, {
        transcript,
        originalName,
        mappedName: mappedName || '',
        confidence,
        meta,
        params: pruned
      });
      if (this.isLawVoiceMode()) {
        const adaptiveIntentName = mappedName || meta?.guessed_intent || 'unknown';
        this.updateAdaptiveContext(
          transcript,
          { ...meta, ...params, ...pruned, intent_name: adaptiveIntentName },
          adaptiveIntentName
        );
        this.rebuildLawVoicePrompt(`intent:${adaptiveIntentName}`);
      }
      if (!name) {
        this.agentLog('Intent detection: no action identified, requesting clarification', 'intent');
        this.sendContextText(this.buildClarificationPrompt(fallbackClarifyText, transcript));
        return;
      }

      this.agentLog(`Detected intent: ${mappedName}`, 'intent');

      if (!this.isAdminView() && ADMIN_ONLY_TOOL_NAMES.has(mappedName)) {
        this.sendContextText('Я могу помочь советом и рекомендацией по правовой ситуации, но служебные действия и материалы доступны только администратору.');
        return;
      }

      if (mappedName === 'clarify_intent' || meta?.clarify) {
        const question = params.question || fallbackClarifyText;
        this.sendContextText(this.buildClarificationPrompt(question, transcript));
        return;
      }

      if (mappedName === '__smalltalk__') {
        this.lawVoiceDialog.resetClarificationCount();
        this.intentDialogState = this.lawVoiceDialog.getStateSnapshot();
        this.sendContextText(meta?.reply || 'Да, на связи. Чем помочь?');
        return;
      }

      const lawVoiceIntents = new Set([
        'legal_support_request',
        'detention_help',
        'cyberbullying_help',
        'school_rights_help',
        'online_purchase_rights_help',
        'emergency_help',
        'goodbye'
      ]);
      if (lawVoiceIntents.has(mappedName)) {
        const contextResult = this.registerIntentContext(mappedName, params, transcript, meta);
        let directive = contextResult.directive;
        if (mappedName === 'legal_support_request' && this.isAdminView()) {
          this.agentLog('Auto action-plan requested', 'intent');
          const plan = await this.requestActionPlanForLegalSupport(
            transcript,
            params,
            contextResult.state
          );
          const planDirective = this.buildActionPlanDirective(plan);
          if (planDirective) {
            directive = `${directive}\n\n${planDirective}`;
          }
        }
        this.sendContextText(directive);
        return;
      }
      switch (mappedName) {
        case 'search_products': {
          if (!COMMERCE_CATALOG_ENABLED) {
            this.sendContextText('Коммерческий каталог отключён. Я могу искать и использовать только материалы базы знаний LawVoice.');
            break;
          }
          const attrsRaw = pruned;
          const attrs = normalizeSpecAttrs(attrsRaw);
          const hasAnySpec = Object.keys(attrs).length > 0;

          if (hasAnySpec) {
            try {
              const resp = await strictSearchByParams(attrs);
              const summary = summaryFromStrictResponse(resp);
              await registerTtsStart();
              speak(summary);
              this.logAgent && this.logAgent(`STRICT: ${summary}`);
              this.emit && this.emit('search_result', resp);
            } catch (e) {
              console.error('strict search failed', e);
              this.logAgent && this.logAgent('Не удалось выполнить строгий поиск.');
            }
            break;
          }

          const query = params.query_text || '';
          this.agentLog(`Searching DB with query="${query}"`, 'tool');
          this.eventLog.push({ action: 'tool_call', tool: 'search_products', query });
          this.updateDebugInfo();
          try {
            const products =  await this.searchProducts(query);
            logger.info('🛢️ DB search result', { query, count: products.length });
            this.eventLog.push({ action: 'tool_result', tool: 'search_products', query, count: products.length });
            this.updateDebugInfo();
            this.log('system', `Search result: ${JSON.stringify(products)}`);

            if (!products || products.length === 0) {
              this.sendContextText("Не нашёл точного совпадения. Попробуем подобрать из похожего ассортимента?");
            } else if (products.length === 1) {
              const it = products[0];
              //session.chosen_item = it;
              this.sendContextText(`Нашёл: ${it.name}. Сколько листов вам нужно?`);
             // state.stage = "awaiting_quantity";
            } else {
              const top = products.slice(0,3);
              this.sendContextText(`Нашёл несколько вариантов: 1) ${top[0].name}; 2) ${top[1]?.name || ""}${top[2] ? "; 3) "+top[2].name : ""}. Какой выбрать?`);
             // state.stage = "awaiting_choice";
              //state.found_options = top;
            }

            const top = products.slice(0, 5)
                .map(p => `${p.name}: ${Math.round(p.price_cents / 100)} ₽ (SKU ${p.sku})`)
                .join('\n');

            this.agentLog(`DB search completed for query="${query}"`, 'tool');
            this.log('system', `Search result: ${JSON.stringify(top)}`);

          } catch (err) {
            console.error(err);
            logger.error('Product search failed', err);
            this.eventLog.push({ action: 'tool_error', tool: 'search_products', query, error: err.message });
            this.updateDebugInfo();
            await this.sendContextText("Произошла ошибка при поиске – попробуйте позже.");
          }
          break;
        }
        case 'list_products': {
          if (!COMMERCE_CATALOG_ENABLED) {
            this.sendContextText('Коммерческий каталог отключён. Материалы LawVoice доступны в разделе базы знаний.');
            break;
          }
          // Enumerate a subset of products when the user asks for the assortment.
          const limit = params.limit || 10;
          this.agentLog(`Listing first ${limit} products`, 'tool');
          this.eventLog.push({ action: 'tool_call', tool: 'list_products', limit });
          this.updateDebugInfo();
          try {
            const r = await fetch(`/api/products?limit=${encodeURIComponent(limit)}`);
            if (!r.ok) throw new Error(await r.text());
            const products = await r.json();
            // Create a human‑readable summary with names and prices
            const summary = products.slice(0, limit).map(p => {
              const price = p.price_rub_m2 ? Number(p.price_rub_m2).toFixed(2) : '—';
              return `${p.name} — ${price}₽/м²`;
            }).join('\n');
            this.eventLog.push({ action: 'tool_result', tool: 'list_products', count: products.length });
            this.updateDebugInfo();
            this.sendContextText(summary);
          } catch (err) {
            console.error(err);
            this.eventLog.push({ action: 'tool_error', tool: 'list_products', error: err.message });
            this.updateDebugInfo();
            this.log('error', `Failed to list products: ${err.message}`);
          }
          break;
        }
        case 'list_categories': {
          if (!COMMERCE_CATALOG_ENABLED) {
            this.sendContextText('Коммерческий каталог отключён. Для LawVoice используются документы базы знаний.');
            break;
          }
          // Return the available product categories derived from product names
          const limit = params.limit || '';
          this.agentLog('Listing product categories', 'tool');
          this.eventLog.push({ action: 'tool_call', tool: 'list_categories', limit });
          this.updateDebugInfo();
          try {
            const qs = limit ? `?limit=${encodeURIComponent(limit)}` : '';
            const r = await fetch(`/api/products/categories${qs}`);
            if (!r.ok) throw new Error(await r.text());
            const categories = await r.json();
            this.eventLog.push({ action: 'tool_result', tool: 'list_categories', count: categories.length });
            this.updateDebugInfo();
            const text = categories.join(', ');
            this.sendContextText(`Доступные категории: ${text}`);
          } catch (err) {
            console.error(err);
            this.eventLog.push({ action: 'tool_error', tool: 'list_categories', error: err.message });
            this.updateDebugInfo();
            this.log('error', `Failed to list categories: ${err.message}`);
          }
          break;
        }
        case 'add_to_cart': {
          const id  = params.product_id;
          const qty = params.qty || 1;
          if (id) {
            this.agentLog(`Tool add_to_cart product_id=${id} qty=${qty}`, 'tool');
            logger.info('🛒 add_to_cart', { id, qty });
            this.eventLog.push({ action: 'tool_call', tool: 'add_to_cart', id, qty });
            this.updateDebugInfo();
            this.cart.push({ product_id: id, qty });
            localStorage.setItem('cart', JSON.stringify(this.cart));
            this.renderCart();
            this.log('system', `Added product ${id} ×${qty} to cart`);
            const r = await fetch('/api/cart', {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json',
                Authorization: `Bearer ${localStorage.getItem('jwt') || ''}`,
                'X-CSRF-Token': csrf
              },
              body: JSON.stringify({ user_id: this.currentUserId, product_id: id, qty })
            });
            const out = await r.json().catch(() => ({}));
            if (r.ok) {
              this.cartTotal = out.subtotal || 0;
              this.eventLog.push({ action: 'tool_result', tool: 'add_to_cart', id, qty, subtotal: this.cartTotal });
              this.updateDebugInfo();
              this.sendContextText(`Промежуточная сумма: ${this.cartTotal}₽`);
            } else {
              this.eventLog.push({ action: 'tool_error', tool: 'add_to_cart', id, qty, error: out.error || r.statusText });
              this.updateDebugInfo();
              this.log('error', `Add to cart failed: ${out.error || r.statusText}`);
          }
          }
          break;
        }
        case 'checkout': {
          const addr = this.orderDetails.address || '';
          const name = this.orderDetails.contact_name || '';
          const phone = this.orderDetails.phone || '';
          this.eventLog.push({ action: 'tool_call', tool: 'checkout', items: this.cart.length });
          this.updateDebugInfo();
          try {
          const r = await fetch('/api/orders', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              Authorization: `Bearer ${localStorage.getItem('jwt') || ''}`,
              'X-CSRF-Token': csrf
            },
              body: JSON.stringify({ user_id: this.currentUserId, items: this.cart, ...this.orderDetails })
          });
            const out = await r.json();
            if (r.ok) {
              this.eventLog.push({ action: 'tool_result', tool: 'checkout', order_id: out.order?.id });
            this.updateDebugInfo();
          this.displayOrders(out.orders || []);
          this.cart = [];
          this.renderCart();
              this.orderDetails = {};
              this.cartTotal = 0;
          this.log('system', 'Order successfully placed');
            } else {
              throw new Error(out.error || r.statusText);
            }
          } catch (err) {
            console.error(err);
            logger.error('Checkout failed', err);
            this.eventLog.push({ action: 'tool_error', tool: 'checkout', error: err.message });
            this.updateDebugInfo();
            await this.sendContextText(`Не удалось оформить заказ: ${err.message}`);
          }
          break;
        }

        case 'view_cart':
          this.agentLog('Tool view_cart', 'tool');
          this.eventLog.push({ action: 'tool_call', tool: 'view_cart', items: this.cart.length });
          this.updateDebugInfo();
          this.renderCart();
          break;

        default:
          this.agentLog(`Unknown tool: ${mappedName}`, 'intent');
          this.log('error', `Unknown tool: ${mappedName}`);
          this.sendContextText(this.buildClarificationPrompt('Сейчас не совсем понял запрос.', transcript));
      }
    } catch (err) {
      this.log('error', `Intent classification failed: ${err.message}`);
    }
  }
  // Detect price queries in transcripts and fetch product data from the server
  async handleProductQuery(transcript) {
    if (!COMMERCE_CATALOG_ENABLED || this.isLawVoiceMode()) return;
    const match = transcript.match(/цена\s+(.+)/i);
    if (!match) return;
    const query = match[1].trim();
    try {
      const products = await this.searchProducts(query);
      this.log('system', `Queried DB for "${query}", found ${products.length} products`);

      if (products.length > 0) {
        this.lastSearchResults = products;
        this.phase = 'search_results';
        const formatted = products
            .map(p => `${p.name} - ${p.price_rub_m2}₽/м², ${p.thickness_mm}мм`)
            .join('; ');
        // Speak found products to the user
        this.sendContextText(`Найдены позиции: ${formatted}`);
      }
    } catch (err) {
      this.log('error', `Product search failed: ${err.message}`);
    }
  }

  trackTokenUsage(event) {
    // Track token usage based on event types and data
    try {
      const currentModel = this.sessionData?.model || "gpt-realtime-mini";
      const modelPricing = this.modelPricing[currentModel] || this.pricing;

      switch (event.type) {
        case 'conversation.item.input_audio_transcription.completed':
          // User audio input was transcribed
          if (event.transcript) {
            const estimatedTokens = this.estimateTokens(event.transcript);
            const estimatedCost = (estimatedTokens / 1000000) * modelPricing.audioInput;
            this.addTokenUsage('input_audio', estimatedTokens);
            this.log('system', `Audio input: ~${estimatedTokens} tokens (~$${estimatedCost.toFixed(4)})`);
          }
          break;

        case 'response.audio_transcript.done':
          // Assistant audio output was transcribed
          if (event.transcript) {
            const estimatedTokens = this.estimateTokens(event.transcript);
            const estimatedCost = (estimatedTokens / 1000000) * modelPricing.audioOutput;
            this.addTokenUsage('output_audio', estimatedTokens);
            this.log('system', `Audio output: ~${estimatedTokens} tokens (~$${estimatedCost.toFixed(4)})`);
          }
          break;

        case 'conversation.item.created':
          // Track text-based inputs/outputs
          if (event.item?.content?.[0]?.text) {
            const tokens = this.estimateTokens(event.item.content[0].text);
            if (event.item.role === 'user') {
              const estimatedCost = (tokens / 1000000) * modelPricing.textInput;
              this.addTokenUsage('input_text', tokens);
              this.log('system', `Text input: ~${tokens} tokens (~$${estimatedCost.toFixed(4)})`);
            } else if (event.item.role === 'assistant') {
              const estimatedCost = (tokens / 1000000) * modelPricing.textOutput;
              this.addTokenUsage('output_text', tokens);
              this.log('system', `Text output: ~${tokens} tokens (~$${estimatedCost.toFixed(4)})`);
            }
          }
          break;

        case 'response.usage':
          // If OpenAI provides actual usage data, use that instead of estimates
          if (event.usage) {
            this.log('system', `Actual usage data received: ${JSON.stringify(event.usage)}`);
            // Update with actual token counts if provided
            if (event.usage.input_tokens) {
              this.tokenUsage.inputTextTokens = event.usage.input_tokens;
              this.tokenUsage.inputAudioTokens = event.usage.input_audio_tokens || 0;
            }
            if (event.usage.output_tokens) {
              this.tokenUsage.outputTextTokens = event.usage.output_tokens;
              this.tokenUsage.outputAudioTokens = event.usage.output_audio_tokens || 0;
            }
            this.updateTokenDisplay();
          }
          break;
      }
    } catch (error) {
      logger.warn('Error tracking token usage:', error);
    }
  }

  estimateTokens(text) {
    // Rough estimation: 1 token ≈ 4 characters for English text
    // This is an approximation since actual tokenization depends on the specific tokenizer
    if (!text) return 0;
    return Math.ceil(text.length / 4);
  }

  getEstimatedSessionCost() {
    const currentModel = this.sessionData?.model || "gpt-realtime-mini";
    const modelPricing = this.modelPricing[currentModel] || this.pricing;
    return (
      (this.tokenUsage.inputTextTokens / 1_000_000) * modelPricing.textInput +
      (this.tokenUsage.inputAudioTokens / 1_000_000) * modelPricing.audioInput +
      (this.tokenUsage.outputTextTokens / 1_000_000) * modelPricing.textOutput +
      (this.tokenUsage.outputAudioTokens / 1_000_000) * modelPricing.audioOutput
    );
  }

  configureSessionCostLimit() {
    const parsed = Number(this.sessionData?.session_cost_limit_usd);
    if (Number.isFinite(parsed) && parsed > 0) {
      this.sessionCostLimitUsd = parsed;
      this.costLimitReached = false;
      this.log('system', `Session cost cap: $${parsed.toFixed(2)}`);
      return;
    }
    this.sessionCostLimitUsd = Number.POSITIVE_INFINITY;
    this.costLimitReached = false;
  }

  enforceSessionCostCap(currentCost = null) {
    if (!Number.isFinite(this.sessionCostLimitUsd) || this.sessionCostLimitUsd <= 0) {
      return false;
    }
    if (this.costLimitReached) {
      return true;
    }
    const totalCost = Number.isFinite(currentCost) ? currentCost : this.getEstimatedSessionCost();
    if (!Number.isFinite(totalCost) || totalCost + 1e-9 < this.sessionCostLimitUsd) {
      return false;
    }

    this.costLimitReached = true;
    const message = `Session cost cap reached ($${this.sessionCostLimitUsd.toFixed(2)}). Stopping session.`;
    this.log('system', message);
    this.agentLog(message, 'tool');
    setTimeout(() => {
      this.stopSession();
    }, 0);
    return true;
  }

  appendAssistantTranscript(delta) {
    let lastEntry = this.elements.conversationLog.lastElementChild;

    // Check if the last entry is an assistant entry that's currently being streamed
    if (!lastEntry || !lastEntry.classList.contains('log-assistant-streaming')) {
      // Create new assistant entry for streaming
      const timestamp = new Date().toLocaleTimeString();
      const logEntry = document.createElement('div');
      logEntry.className = 'log-entry log-assistant log-assistant-streaming log-assistant-speaking';

      logEntry.innerHTML = `
        <div class="log-timestamp">${timestamp}</div>
        <div class="log-content"></div>
      `;

      this.elements.conversationLog.appendChild(logEntry);
      lastEntry = logEntry;
    }

    // Append the delta to the content
    const contentDiv = lastEntry.querySelector('.log-content');
    contentDiv.textContent += delta;
    this.elements.conversationLog.scrollTop = this.elements.conversationLog.scrollHeight;
  }

  finalizeAssistantTranscript(fullTranscript) {
    let lastEntry = this.elements.conversationLog.lastElementChild;

    if (lastEntry && lastEntry.classList.contains('log-assistant-streaming')) {
      // Update the streaming entry with the final transcript
      const contentDiv = lastEntry.querySelector('.log-content');
      contentDiv.textContent = fullTranscript;

      // Remove streaming classes
      lastEntry.classList.remove('log-assistant-streaming', 'log-assistant-speaking');
    } else {
      // Create a new entry if no streaming entry exists
      this.log('assistant', fullTranscript);
    }
  }

  ensureAssistantTranscript(transcript) {
    let lastEntry = this.elements.conversationLog.lastElementChild;

    // Check if we already have this transcript
    if (lastEntry && lastEntry.classList.contains('log-assistant')) {
      const contentDiv = lastEntry.querySelector('.log-content');
      if (contentDiv.textContent.trim() === transcript.trim()) {
        // We already have this transcript, just clean up classes
        lastEntry.classList.remove('log-assistant-streaming', 'log-assistant-speaking');
        return;
      }
    }

    // If we don't have the transcript or it's different, add/update it
    if (lastEntry && lastEntry.classList.contains('log-assistant-streaming')) {
      // Update streaming entry
      const contentDiv = lastEntry.querySelector('.log-content');
      contentDiv.textContent = transcript;
      lastEntry.classList.remove('log-assistant-streaming', 'log-assistant-speaking');
    } else {
      // Create new entry
      this.log('assistant', transcript);
    }
  }

  showAssistantSpeaking(speaking) {
    const lastEntry = this.elements.conversationLog.lastElementChild;
    if (lastEntry && (lastEntry.classList.contains('log-assistant') || lastEntry.classList.contains('log-assistant-streaming'))) {
      if (speaking) {
        lastEntry.classList.add('log-assistant-speaking');
      } else {
        lastEntry.classList.remove('log-assistant-speaking');
      }
    }
  }

  toggleMute() {
    if (!this.mediaStream) return;

    this.isMuted = !this.isMuted;
    this.mediaStream.getAudioTracks().forEach(track => {
      track.enabled = !this.isMuted;
    });

    this.elements.muteBtn.textContent = this.isMuted ? 'Unmute' : 'Mute';
    this.elements.muteBtn.classList.toggle('btn-danger', this.isMuted);
    this.elements.muteBtn.classList.toggle('btn-outline', !this.isMuted);

    this.log('system', this.isMuted ? 'Microphone muted' : 'Microphone unmuted');
  }

  async stopSession(endReason = 'manual_stop') {
    if (this.pc) {
      this.pc.close();
      this.pc = null;
    }

    if (this.dataChannel) {
      this.dataChannel.close();
      this.dataChannel = null;
    }

    if (this.mediaStream) {
      this.mediaStream.getTracks().forEach(track => track.stop());
      this.mediaStream = null;
    }

    if (this.audioContext) {
      this.audioContext.close();
      this.audioContext = null;
    }

    if (this.outputAudioElement) {
      this.outputAudioElement.srcObject = null;
      this.outputAudioElement = null;
    }

    this.inputAnalyser = null;
    this.outputAnalyser = null;
    this.isConnected = false;
    this.isMuted = false;

    this.updateStatus('Disconnected', 'disconnected');
    this.elements.startBtn.disabled = false;
    this.elements.stopBtn.disabled = true;
    this.elements.muteBtn.disabled = true;
    this.elements.muteBtn.textContent = 'Mute';
    this.elements.muteBtn.classList.remove('btn-danger');
    this.elements.muteBtn.classList.add('btn-outline');

    // Disable context injection
    this.updateContextButton();

    this.log('system', 'Session ended');
    this.agentLog('Session ended');
    await this.saveSessionRecording(endReason);

    // Send analytics to server
    const durationMs = this.sessionStartTime ? Date.now() - this.sessionStartTime : 0;
    const payload = {
      sessionId: this.sessionData?.id || null,
      durationMs,
      tokens: this.getTotalTokens(),
      queries: this.queryCount
    };
    try {
      await fetch('/api/analytics', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'CSRF-Token': this.elements.csrfToken?.value || ''
        },
        body: JSON.stringify(payload)
      });
      this.loadAnalytics();
    } catch (err) {
      console.error('Failed to send analytics', err);
    }
  }

  updateStatus(connection, type) {
    this.elements.statusConnection.textContent = connection;
    this.elements.statusConnection.className = `status-value status-${type}`;

    // Update other status fields from session data
    if (this.sessionData) {
      this.elements.statusVoice.textContent = this.sessionData.voice || 'Unknown';
      this.elements.statusModel.textContent = this.sessionData.model || 'Unknown';
    }
  }

  connectLogStream() {
    if (!this.isAdminView() || !this.elements.activityLog) return;
    try {
      const source = new EventSource('/api/agent-console');
      source.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          this.agentLog(data.message, data.type);
        } catch (err) {
          logger.error('Invalid log event', err);
        }
      };
      this.logSource = source;
    } catch (err) {
      logger.error('Failed to connect to log stream', err);
    }
  }

  // Record internal agent activity
  agentLog(message, type = 'info') {
    this.recordSessionEvent(type === 'info' ? 'agent' : type, message);
    const container = this.elements.activityLog;
    if (!container) return;
    const timestamp = new Date().toISOString().replace('T', ' ').split('.')[0];
    const entry = document.createElement('div');
    entry.textContent = `${timestamp}: ${message}`;
    if (type === 'intent') entry.style.color = 'green';
    if (type === 'tool') entry.style.color = 'orange';
    container.appendChild(entry);
    container.scrollTop = container.scrollHeight;
  }

  log(type, message) {
    if (type === 'user') {
      this.queryCount++;
    }
    this.recordSessionEntry(type, message);
    const timestamp = new Date().toLocaleTimeString();
    const logEntry = document.createElement('div');
    logEntry.className = `log-entry log-${type}`;

    const timestampNode = document.createElement('div');
    timestampNode.className = 'log-timestamp';
    timestampNode.textContent = timestamp;
    const contentNode = document.createElement('div');
    contentNode.className = 'log-content';
    contentNode.textContent = message;
    logEntry.append(timestampNode, contentNode);

    this.elements.conversationLog.appendChild(logEntry);
    this.elements.conversationLog.scrollTop = this.elements.conversationLog.scrollHeight;
  }

  clearConversationLog() {
    this.elements.conversationLog.innerHTML = '';
    this.log('system', 'Conversation log cleared');

    // Also reset token usage
    this.resetTokenUsage();
    this.log('system', 'Token usage reset');
  }

  updateDebugInfo() {
    if (this.sessionData) {
      this.elements.sessionInfo.textContent = JSON.stringify({
        model: this.sessionData.model,
        voice: this.sessionData.voice,
        expires_at: this.sessionData.expires_at
      }, null, 2);
    }

    this.elements.eventLog.textContent = JSON.stringify(
        this.eventLog.slice(-10), // Show last 10 events
        null,
        2
    );
  }

  updateContextButton() {
    const hasText = this.elements.contextInput.value.trim().length > 0;
    const isConnected = this.isConnected && this.dataChannel && this.dataChannel.readyState === 'open';
    this.elements.sendContextBtn.disabled = !hasText || !isConnected || this.costLimitReached;
  }

  // Generic context injection helper used by UI and automatic product search
  sendContextText(contextText, { interrupt = false, background = false } = {}) {
    if (!contextText || !this.isConnected || this.costLimitReached) return;

    const interruptMode = this.elements.interruptContext.checked || interrupt;
    const backgroundMode = this.elements.backgroundContext.checked || background;

    try {
      this.agentLog(`Injecting context: ${contextText}`);
      // Track tokens for context injection
      const contextTokens = this.estimateTokens(contextText);
      const currentModel = this.sessionData?.model || "gpt-realtime-mini";
      const modelPricing = this.modelPricing[currentModel] || this.pricing;
      const estimatedCost = (contextTokens / 1000000) * modelPricing.textInput;

      this.addTokenUsage('input_text', contextTokens);
      if (this.costLimitReached) return;

      // Cancel current response if interrupt mode is enabled
      if (interruptMode) {
        if (this.hasActiveResponse) {
          this.sendEvent({
            type: 'response.cancel'
          });
          // Immediately mark as inactive to avoid race conditions with pending events
          this.hasActiveResponse = false;
          this.log('system', '🛑 Interrupted current response for context injection');
        } else {
          // Avoid sending cancel when there's no active response
          logger.debug('No active response to cancel');
        }
      }

      // Create context item with provided text
      this.sendEvent({
        type: 'conversation.item.create',
        item: {
          type: 'message',
          role: 'user',
          content: [{ type: 'input_text', text: contextText }]
        }
      });

      this.log('system', `📝 Context injected: ${contextTokens} tokens (~$${estimatedCost.toFixed(4)}) - "${contextText.substring(0, 50)}${contextText.length > 50 ? '...' : ''}"`);

      // Request response unless in background mode
      if (!backgroundMode) {
        this.sendEvent({
          type: 'response.create',
          response: { modalities: ['audio', 'text'] }
        });
        this.log('system', '🤖 Requesting AI response to context');
      } else {
        this.log('system', 'Context processed in background mode (no response requested)');
      }
    } catch (error) {
      this.log('error', `Failed to send context: ${error.message}`);
    }
  }

  // Wrapper for manual context injection from UI
  sendContext() {
    const contextText = this.elements.contextInput.value.trim();
    const interruptMode = this.elements.interruptContext.checked;
    const backgroundMode = this.elements.backgroundContext.checked;

    this.sendContextText(contextText, { interrupt: interruptMode, background: backgroundMode });

    // Clear the input and update button state
    this.elements.contextInput.value = '';
    this.updateContextButton();

    const modeDescription = [
      interruptMode ? 'Interrupt: ON' : 'Interrupt: OFF',
      backgroundMode ? 'Background: ON' : 'Background: OFF'
    ].join(', ');
    this.log('system', `Context injection mode: ${modeDescription}`);
  }

  sendEvent(event) {
    if (this.dataChannel && this.dataChannel.readyState === 'open') {
      this.dataChannel.send(JSON.stringify(event));
      logger.debug('Sent event:', event);
    } else {
      throw new Error('Data channel not available');
    }
  }

    updateTokenDisplay() {
      return updateTokenDisplayFn(this);
    }

    updateCostDisplay() {
      return updateCostDisplayFn(this);
    }

    updatePricingDisplay() {
      return updatePricingDisplayFn(this);
    }

  async fetchCsrfToken() {
    try {
      const res = await fetch('/api/csrf-token', {
        credentials: 'same-origin'
      });
      if (!res.ok) {
        const details = await readErrorMessage(res);
        throw new Error(`CSRF token request failed (${res.status}): ${details}`);
      }
      const data = await res.json();
      this.csrfToken = data.csrfToken;
      if (this.elements.csrfToken) {
        this.elements.csrfToken.value = data.csrfToken;
      }
      return data.csrfToken;
    } catch (err) {
      logger.error('Failed to fetch CSRF token', err);
      return null;
    }
  }

  async fetchAuthToken() {
    try {
      const res = await fetch('/api/auth/token');
      if (!res.ok) {
        return null;
      }
      const data = await res.json();
      if (data.token) {
        localStorage.setItem('jwt', data.token);
        return data.token;
      }
      return null;
    } catch (err) {
      logger.error('Token fetch fail', err);
      return null;
    }
  }

  isAdminView() {
    return Boolean(this.authState?.isAdmin);
  }

  setAdminError(message = '') {
    if (!this.elements.adminLoginError) return;
    this.elements.adminLoginError.hidden = !message;
    this.elements.adminLoginError.textContent = message;
  }

  closeLogStream() {
    if (this.logSource) {
      this.logSource.close();
      this.logSource = null;
    }
  }

  applyAdminUi() {
    const isAdmin = this.isAdminView();
    document.body.dataset.role = isAdmin ? 'admin' : 'user';
    document.querySelectorAll('[data-admin-only]').forEach((element) => {
      element.classList.toggle('is-hidden-by-role', !isAdmin);
    });
    if (this.elements.profileDetails && !isAdmin) {
      this.elements.profileDetails.open = false;
    }
    if (this.elements.adminRoleBadge) {
      this.elements.adminRoleBadge.textContent = isAdmin ? 'Администратор' : 'Пользователь';
    }
    if (this.elements.adminAuthStatus) {
      this.elements.adminAuthStatus.textContent = isAdmin
        ? 'Режим администратора: доступны материалы, управление профилями и observability.'
        : 'Пользовательский режим: доступен только диалог и рекомендации.';
    }
    if (this.elements.adminLoginBtn) {
      this.elements.adminLoginBtn.hidden = isAdmin;
      this.elements.adminLoginBtn.classList.toggle('is-hidden-by-role', isAdmin);
    }
    if (this.elements.adminLogoutBtn) {
      this.elements.adminLogoutBtn.hidden = !isAdmin;
      this.elements.adminLogoutBtn.classList.toggle('is-hidden-by-role', !isAdmin);
    }
    if (this.elements.adminLoginKey) {
      this.elements.adminLoginKey.hidden = isAdmin;
      this.elements.adminLoginKey.disabled = isAdmin;
      this.elements.adminLoginKey.classList.toggle('is-hidden-by-role', isAdmin);
      if (isAdmin) {
        this.elements.adminLoginKey.value = '';
      }
    }
    const monitoring = this.authState?.observability || null;
    if (monitoring?.grafanaUrl && this.elements.grafanaLink) {
      this.elements.grafanaLink.href = monitoring.grafanaUrl;
    }
    if (monitoring?.prometheusUrl && this.elements.prometheusLink) {
      this.elements.prometheusLink.href = monitoring.prometheusUrl;
    }
    if (monitoring?.metricsUrl && this.elements.metricsLink) {
      this.elements.metricsLink.href = monitoring.metricsUrl;
    }
    if (this.elements.observabilityStatus) {
      this.elements.observabilityStatus.textContent = isAdmin
        ? 'Grafana, Prometheus и endpoint метрик доступны для контроля стека.'
        : 'Панель мониторинга доступна администратору.';
    }
    this.updateKnowledgeAdminUi();
    if (isAdmin) {
      if (!this.logSource) {
        this.connectLogStream();
      }
      this.loadKnowledgeDocuments();
      return;
    }
    this.closeLogStream();
    this.knowledgeDocuments = [];
    this.renderKnowledgeDocuments([], 'Доступно только администратору.');
    this.setKnowledgeStatus('Загрузка и управление базой знаний доступны только администратору.', false);
  }

  async refreshAuthState({ silent = false } = {}) {
    try {
      const res = await fetch('/api/auth/me', { cache: 'no-store', credentials: 'same-origin' });
      if (!res.ok) {
        throw new Error(`Auth state request failed: ${res.status}`);
      }
      this.authState = await res.json();
      this.applyAdminUi();
      if (!silent) {
        this.setAdminError('');
      }
      return this.authState;
    } catch (err) {
      logger.error('Failed to refresh auth state', err);
      this.authState = { role: 'user', isAdmin: false, canManage: false, observability: null };
      this.applyAdminUi();
      if (!silent) {
        this.setAdminError('Не удалось обновить статус авторизации.');
      }
      return this.authState;
    }
  }

  async submitAdminLogin(event) {
    event.preventDefault();
    const apiKey = (this.elements.adminLoginKey?.value || '').trim();
    if (!apiKey) {
      this.setAdminError('Введите ADMIN_API_KEY.');
      return;
    }
    this.setAdminError('');
    try {
      const res = await fetch('/api/auth/admin/login', {
        method: 'POST',
        credentials: 'same-origin',
        headers: this.buildApiHeaders(true),
        body: JSON.stringify({ apiKey })
      });
      if (!res.ok) {
        const details = await readErrorMessage(res);
        throw new Error(details || 'Не удалось выполнить вход.');
      }
      this.authState = await res.json();
      this.applyAdminUi();
      this.setAdminError('');
    } catch (err) {
      logger.error('Admin login failed', err);
      this.setAdminError('Ошибка входа администратора. Проверьте ключ.');
    }
  }

  async logoutAdmin() {
    try {
      await fetch('/api/auth/logout', {
        method: 'POST',
        credentials: 'same-origin',
        headers: this.buildApiHeaders(false)
      });
    } catch (err) {
      logger.error('Admin logout failed', err);
    } finally {
      this.authState = { role: 'user', isAdmin: false, canManage: false, observability: null };
      this.applyAdminUi();
      this.setAdminError('');
    }
  }

  updateKnowledgeAdminUi() {
    const isAdmin = this.isAdminView();
    [
      this.elements.knowledgeTitle,
      this.elements.knowledgeFile,
      this.elements.uploadKnowledgeBtn,
      this.elements.refreshKnowledgeBtn,
      this.elements.knowledgeSearch
    ].forEach((element) => {
      if (element) {
        element.disabled = !isAdmin;
      }
    });
  }

  buildApiHeaders(includeJson = true) {
    const headers = {};
    if (includeJson) {
      headers['Content-Type'] = 'application/json';
    }
    const token = localStorage.getItem('jwt') || '';
    if (token) {
      headers.Authorization = `Bearer ${token}`;
    }
    const csrf = this.csrfToken || this.elements.csrfToken?.value || '';
    if (csrf) {
      headers['X-CSRF-Token'] = csrf;
    }
    return headers;
  }

  buildLawVoiceActionPlanContext(state = {}) {
    const scenario = state?.scenario || 'general_legal';
    const stage = state?.stage || 'fact_gathering';
    const risk = state?.risk_level || 'medium';
    const facts = state?.facts || {};
    const factsText = Object.entries(facts)
      .filter(([, value]) => value !== null && value !== undefined && value !== '')
      .map(([key, value]) => `${key}: ${typeof value === 'boolean' ? (value ? 'да' : 'нет') : value}`)
      .join('; ');
    return [
      `Сценарий: ${scenario}`,
      `Стадия: ${stage}`,
      `Риск: ${risk}`,
      `Факты: ${factsText || 'критичные факты пока не собраны'}`
    ].join('\n');
  }

  buildActionPlanDirective(plan) {
    const steps = Array.isArray(plan?.steps) ? plan.steps : [];
    if (!steps.length) return '';
    const summary = typeof plan.summary === 'string' && plan.summary.trim()
      ? plan.summary.trim()
      : 'Сформирован план действий.';
    const stepLines = steps.slice(0, 5).map((step, index) => {
      const action = `${step?.action || ''}`.trim();
      const rationaleRaw = `${step?.rationale || ''}`.replace(/\s+/g, ' ').trim();
      const rationale = rationaleRaw.length > 180
        ? `${rationaleRaw.slice(0, 177)}...`
        : rationaleRaw;
      return `${index + 1}) ${action}${rationale ? ` — ${rationale}` : ''}`;
    });
    const knowledgeCount = Number(plan?.knowledge?.count || 0);
    return [
      'Автоматически обновленный план действий (опора на контекст и базу знаний):',
      `Резюме: ${summary}`,
      'Шаги:',
      ...stepLines,
      knowledgeCount > 0
        ? `Основано на фрагментах базы знаний: ${knowledgeCount}.`
        : 'База знаний не дала прямых совпадений, использован безопасный черновой план.',
      'Используй план как основу ответа и задай один вопрос: какой шаг выполнить первым?'
    ].join('\n');
  }

  renderLawVoiceActionPlan(plan) {
    if (!this.isLawVoiceMode()) return;
    if (!this.elements.cartTableBody) return;
    const steps = Array.isArray(plan?.steps) ? plan.steps : [];
    if (!steps.length) return;

    this.elements.cartTableBody.innerHTML = '';
    steps.forEach((step, index) => {
      const tr = document.createElement('tr');

      const stepCell = document.createElement('td');
      stepCell.textContent = `${index + 1}. ${step?.action || ''}`;
      tr.appendChild(stepCell);

      const priorityCell = document.createElement('td');
      const status = `${step?.status || 'todo'}`.toLowerCase();
      const statusMap = {
        todo: 'Новый',
        in_progress: 'В работе',
        done: 'Готово'
      };
      priorityCell.textContent = statusMap[status] || 'Новый';
      tr.appendChild(priorityCell);

      const commentCell = document.createElement('td');
      const rationale = `${step?.rationale || ''}`.replace(/\s+/g, ' ').trim();
      commentCell.textContent = rationale || 'Без комментария';
      tr.appendChild(commentCell);

      this.elements.cartTableBody.appendChild(tr);
    });

    if (this.elements.cartTotal) {
      this.elements.cartTotal.textContent = String(steps.length);
    }
  }

  async requestActionPlanForLegalSupport(transcript, params = {}, dialogState = {}) {
    const objective = `${params?.query_text || transcript || ''}`.trim();
    if (!objective) return null;
    if (!this.isAdminView()) return null;

    const now = Date.now();
    const normalizedObjective = objective.toLowerCase();
    const duplicateRequest =
      normalizedObjective === this.lastActionPlanObjective &&
      now - this.lastActionPlanRequestedAt < 5000;
    if (duplicateRequest) {
      this.agentLog('Action-plan skipped: duplicate objective in cooldown', 'intent');
      return this.currentActionPlan;
    }
    this.lastActionPlanObjective = normalizedObjective;
    this.lastActionPlanRequestedAt = now;

    const constraints = [
      'Не запрашивать лишние персональные данные.',
      'Опора только на подтвержденные факты и знания.',
      'Давать безопасные и правомерные шаги.'
    ];
    if (`${dialogState?.risk_level || ''}`.toLowerCase() === 'high') {
      constraints.push('Первым шагом указывать действия по безопасности.');
    }

    const payload = {
      objective,
      context: this.buildLawVoiceActionPlanContext(dialogState),
      constraints,
      current_plan: Array.isArray(this.currentActionPlan?.steps) ? this.currentActionPlan.steps : [],
      knowledge_query: objective
    };

    this.eventLog.push({
      action: 'action_plan_request',
      objective,
      has_current_plan: Array.isArray(payload.current_plan) && payload.current_plan.length > 0
    });
    this.updateDebugInfo();

    try {
      const response = await fetch('/api/action-plan', {
        method: 'POST',
        headers: this.buildApiHeaders(true),
        body: JSON.stringify(payload)
      });
      if (!response.ok) {
        const details = await readErrorMessage(response);
        throw new Error(details);
      }

      const plan = await response.json();
      this.currentActionPlan = plan;
      this.renderLawVoiceActionPlan(plan);
      this.eventLog.push({
        action: 'action_plan_result',
        mode: plan?.mode || 'draft',
        steps: Array.isArray(plan?.steps) ? plan.steps.length : 0,
        knowledge_hits: Number(plan?.knowledge?.count || 0)
      });
      this.updateDebugInfo();
      return plan;
    } catch (err) {
      logger.error('Action-plan request failed', err);
      this.eventLog.push({ action: 'action_plan_error', objective, error: err.message });
      this.updateDebugInfo();
      return null;
    }
  }

  setKnowledgeStatus(message, isError = false) {
    if (!this.elements.knowledgeStatus) return;
    this.elements.knowledgeStatus.textContent = message;
    this.elements.knowledgeStatus.classList.toggle('is-error', Boolean(isError));
  }

  async loadKnowledgeDocuments() {
    if (!this.elements.knowledgeDocumentsBody) return;
    if (!this.isAdminView()) {
      this.knowledgeDocuments = [];
      this.renderKnowledgeDocuments([], 'Доступно только администратору.');
      this.setKnowledgeStatus('Загрузка и управление базой знаний доступны только администратору.', false);
      return;
    }
    const q = (this.elements.knowledgeSearch?.value || '').trim();
    const params = new URLSearchParams({ limit: '100' });
    if (q) params.set('q', q);
    const url = `/api/knowledge/documents?${params.toString()}`;

    try {
      const res = await fetch(url, {
        headers: this.buildApiHeaders(false)
      });
      if (res.status === 401) {
        await this.refreshAuthState({ silent: true });
        throw new Error('Требуется вход администратора');
      }
      if (!res.ok) {
        const details = await readErrorMessage(res);
        throw new Error(details);
      }
      const payload = await res.json();
      const items = Array.isArray(payload?.items) ? payload.items : [];
      this.knowledgeDocuments = items;
      this.renderKnowledgeDocuments(items);
      if (items.length === 0) {
        this.setKnowledgeStatus('Документы не найдены. Загрузите первый файл.', false);
      } else {
        this.setKnowledgeStatus(`Загружено документов: ${items.length}`, false);
      }
    } catch (err) {
      logger.error('Failed to load knowledge documents', err);
      this.renderKnowledgeDocuments([], 'Не удалось загрузить список документов.');
      this.setKnowledgeStatus(`Ошибка загрузки списка: ${err.message}`, true);
    }
  }

  renderKnowledgeDocuments(documents = [], emptyMessage = 'Список документов пуст.') {
    if (!this.elements.knowledgeDocumentsBody) return;
    this.elements.knowledgeDocumentsBody.innerHTML = '';
    if (!documents.length) {
      const emptyRow = document.createElement('tr');
      const cell = document.createElement('td');
      cell.colSpan = 6;
      cell.textContent = emptyMessage;
      emptyRow.appendChild(cell);
      this.elements.knowledgeDocumentsBody.appendChild(emptyRow);
      return;
    }

    documents.forEach((doc) => {
      const row = document.createElement('tr');

      const titleCell = document.createElement('td');
      titleCell.className = 'knowledge-title-cell';
      titleCell.textContent = doc.title || 'Без названия';
      row.appendChild(titleCell);

      const sourceCell = document.createElement('td');
      sourceCell.textContent = doc.source_name || '—';
      row.appendChild(sourceCell);

      const chunksCell = document.createElement('td');
      chunksCell.textContent = String(doc.chunk_count ?? 0);
      row.appendChild(chunksCell);

      const tokensCell = document.createElement('td');
      tokensCell.textContent = String(doc.token_estimate ?? 0);
      row.appendChild(tokensCell);

      const dateCell = document.createElement('td');
      const createdAt = doc.created_at ? new Date(doc.created_at) : null;
      dateCell.textContent = createdAt && !Number.isNaN(createdAt.getTime())
        ? createdAt.toLocaleString('ru-RU')
        : '—';
      row.appendChild(dateCell);

      const actionCell = document.createElement('td');
      const deleteBtn = document.createElement('button');
      deleteBtn.className = 'btn btn-outline btn-small';
      deleteBtn.textContent = 'Удалить';
      deleteBtn.addEventListener('click', () => this.deleteKnowledgeDocument(doc.id, doc.title || 'документ'));
      actionCell.appendChild(deleteBtn);
      row.appendChild(actionCell);

      this.elements.knowledgeDocumentsBody.appendChild(row);
    });
  }

  async uploadKnowledgeDocument() {
    if (!this.isAdminView()) {
      this.setKnowledgeStatus('Для загрузки документа требуется вход администратора.', true);
      return;
    }
    const file = this.elements.knowledgeFile?.files?.[0];
    if (!file) {
      this.setKnowledgeStatus('Выберите файл для загрузки.', true);
      return;
    }

    const maxBytes = 4.5 * 1024 * 1024;
    if (file.size > maxBytes) {
      this.setKnowledgeStatus('Файл слишком большой. Лимит 4.5 MB.', true);
      return;
    }

    const uploadBtn = this.elements.uploadKnowledgeBtn;
    if (uploadBtn) uploadBtn.disabled = true;
    this.setKnowledgeStatus(`Загрузка "${file.name}"...`, false);

    try {
      const text = await file.text();
      if (!text || !text.trim()) {
        throw new Error('Файл пустой или не содержит текстовых данных');
      }
      const title = (this.elements.knowledgeTitle?.value || '').trim() || file.name;
      const payload = {
        title,
        source_name: file.name,
        mime_type: file.type || 'text/plain',
        content: text
      };

      const res = await fetch('/api/knowledge/documents', {
        method: 'POST',
        headers: this.buildApiHeaders(true),
        body: JSON.stringify(payload)
      });
      if (res.status === 401) {
        await this.refreshAuthState({ silent: true });
        throw new Error('Требуется вход администратора');
      }
      if (!res.ok) {
        const details = await readErrorMessage(res);
        throw new Error(details);
      }

      const created = await res.json();
      const chunks = created?.stats?.chunks ?? 0;
      this.setKnowledgeStatus(`Документ загружен: ${title} (чанков: ${chunks})`, false);
      if (this.elements.knowledgeFile) {
        this.elements.knowledgeFile.value = '';
      }
      await this.loadKnowledgeDocuments();
    } catch (err) {
      logger.error('Knowledge document upload failed', err);
      this.setKnowledgeStatus(`Ошибка загрузки: ${err.message}`, true);
    } finally {
      this.updateKnowledgeAdminUi();
    }
  }

  async deleteKnowledgeDocument(documentId, title = 'документ') {
    if (!documentId) return;
    if (!this.isAdminView()) {
      this.setKnowledgeStatus('Для удаления документа требуется вход администратора.', true);
      return;
    }
    const ok = window.confirm(`Удалить документ "${title}"?`);
    if (!ok) return;
    this.setKnowledgeStatus(`Удаление "${title}"...`, false);

    try {
      const res = await fetch(`/api/knowledge/documents/${encodeURIComponent(documentId)}`, {
        method: 'DELETE',
        headers: this.buildApiHeaders(false)
      });
      if (res.status === 401) {
        await this.refreshAuthState({ silent: true });
        throw new Error('Требуется вход администратора');
      }
      if (!res.ok) {
        const details = await readErrorMessage(res);
        throw new Error(details);
      }

      this.setKnowledgeStatus(`Документ удалён: ${title}`, false);
      await this.loadKnowledgeDocuments();
    } catch (err) {
      logger.error('Knowledge document deletion failed', err);
      this.setKnowledgeStatus(`Ошибка удаления: ${err.message}`, true);
    }
  }

  async loadProducts() {
    if (!this.isAdminView()) return [];
    if (!COMMERCE_CATALOG_ENABLED) {
      localStorage.removeItem('products');
      this.products = [];
      if (this.elements.productList) {
        this.elements.productList.innerHTML = '';
        const li = document.createElement('li');
        li.textContent = 'Коммерческий каталог отключён. Используйте базу знаний для документов LawVoice.';
        this.elements.productList.appendChild(li);
      }
      await this.loadKnowledgeDocuments();
      return [];
    }
    try {
      let products = localStorage.getItem('products');
      if (products) {
        products = JSON.parse(products);
      } else {
        const res = await fetch('/api/products');
        if (!res.ok) {
          throw new Error(`Failed to fetch products: ${res.statusText}`);
        }
        products = await res.json();
        localStorage.setItem('products', JSON.stringify(products));
      }
      this.products = products;
      this.displayProducts(products);
    } catch (err) {
      logger.error('Failed to load products:', err);
      this.log('error', `Failed to load products: ${err.message}`);
    }
  }
  displayProducts(products) {
    if (!this.elements.productList) return;
    this.elements.productList.innerHTML = '';
    products.forEach(p => {
      const li = document.createElement('li');
      li.textContent = `${p.name} - ${p.price_rub_m2 ?? ''}`;
      const btn = document.createElement('button');
      btn.textContent = 'Add to Cart';
      btn.className = 'btn btn-small';
      btn.addEventListener('click', () => this.addToCart(p));
      li.appendChild(btn);
      this.elements.productList.appendChild(li);
    });
  }

  filterProducts(term) {
    if (!this.products) return;
    const filtered = this.products.filter(p => p.name.toLowerCase().includes(term.toLowerCase()));
    this.displayProducts(filtered);
  }

  saveCart() {
    localStorage.setItem('cart', JSON.stringify(this.cart));
  }

  renderCart() {
    if (!this.elements.cartTableBody) return;
    this.elements.cartTableBody.innerHTML = '';
    let total = 0;
    this.cart.forEach(item => {
      const subtotal = (item.price ?? 0) * item.qty;
      total += subtotal;
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${item.name}</td><td>${item.qty}</td><td>${subtotal.toFixed(2)}</td>`;
      this.elements.cartTableBody.appendChild(tr);
    });
    if (this.elements.cartTotal) {
      this.elements.cartTotal.textContent = total.toFixed(2);
    }
  }

  addToCart(product) {
    const existing = this.cart.find(i => i.id === product.id);
    if (existing) {
      existing.qty += 1;
    } else {
      this.cart.push({ id: product.id, name: product.name, price: product.price_rub_m2, qty: 1 });
    }
    this.saveCart();
    this.renderCart();
  }

  async submitOrder() {
    if (!this.isAdminView()) return;
    if (!this.cart.length) return;
    const items = this.cart.map(item => ({
      product_id: item.id,
      qty: item.qty,
      total: (item.price ?? 0) * item.qty
    }));
    try {
      const res = await fetch('/api/orders', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-User-Id': localStorage.getItem('user_id') || '1',
          'CSRF-Token': this.elements.csrfToken?.value || ''
        },
        body: JSON.stringify({ items })
      });
      if (res.ok) {
        this.cart = [];
        this.saveCart();
        this.renderCart();
        console.log('Order submitted');
      } else {
        console.error('Order submission failed');
      }
    } catch (err) {
      console.error('Order submission error', err);
    }
  }

  addTokenUsage(type, tokens) {
    // Add tokens to the appropriate counter
    if (tokens > 0) {
      switch(type) {
        case 'input_text':
          this.tokenUsage.inputTextTokens += tokens;
          break;
        case 'input_audio':
          this.tokenUsage.inputAudioTokens += tokens;
          break;
        case 'output_text':
          this.tokenUsage.outputTextTokens += tokens;
          break;
        case 'output_audio':
          this.tokenUsage.outputAudioTokens += tokens;
          break;
      }
      this.updateTokenDisplay();
    }
  }

    resetTokenUsage() {
      return resetTokenUsageFn(this);
    }

    getTotalTokens() {
      return getTotalTokensFn(this);
    }

  async loadAnalytics() {
    try {
      const res = await fetch('/api/analytics');
      if (!res.ok) {
        console.warn(`Analytics endpoint returned ${res.status}`);
        return;
      }
      const data = await res.json();
      if (!Array.isArray(data)) {
        console.warn('Analytics payload is not an array');
        return;
      }
      const labels = data.map(d => new Date(d.created_at).toLocaleTimeString());
      const tokenData = data.map(d => d.tokens);
      const sessionData = data.map(d => d.duration_ms / 1000);
      const totalQueries = data.reduce((sum, d) => sum + (d.queries || 0), 0);
      const qEl = document.getElementById('total-queries');
      if (qEl) qEl.textContent = totalQueries;
      this.renderAnalyticsCharts(labels, sessionData, tokenData);
    } catch (err) {
      console.error('Failed to load analytics', err);
    }
  }

  renderAnalyticsCharts(labels, sessionsData, tokensData) {
    const sessionCtx = document.getElementById('sessionsChart')?.getContext('2d');
    const tokenCtx = document.getElementById('tokensChart')?.getContext('2d');

    if (sessionCtx) {
      if (!this.sessionsChart) {
        this.sessionsChart = new Chart(sessionCtx, {
          type: 'line',
          data: {
            labels,
            datasets: [{
              label: 'Session Duration (s)',
              data: sessionsData,
              borderColor: '#10a37f',
              fill: false
            }]
          },
          options: { scales: { y: { beginAtZero: true } } }
        });
      } else {
        this.sessionsChart.data.labels = labels;
        this.sessionsChart.data.datasets[0].data = sessionsData;
        this.sessionsChart.update();
      }
    }

    if (tokenCtx) {
      if (!this.tokensChart) {
        this.tokensChart = new Chart(tokenCtx, {
          type: 'bar',
          data: {
            labels,
            datasets: [{
              label: 'Tokens',
              data: tokensData,
              backgroundColor: '#6366f1'
            }]
          },
          options: { scales: { y: { beginAtZero: true } } }
        });
      } else {
        this.tokensChart.data.labels = labels;
        this.tokensChart.data.datasets[0].data = tokensData;
        this.tokensChart.update();
      }
    }
  }

    detectVoiceActivity(inputLevel) {
      return detectVoiceActivityFn(this, inputLevel);
    }

  displayOrders(orders) {
    // Display orders in UI or log for debug
    console.log('Orders:', orders);
    this.log('system', `Orders: ${JSON.stringify(orders)}`);
    // Optionally render in a new UI element
  }
}

// Initialize the voice agent when the page loads
document.addEventListener('DOMContentLoaded', () => {
  window.voiceAgent = new VoiceAgent();
  window.voiceAgent.loadAnalytics();
  console.log('OpenAI Realtime Voice Agent initialized');
});

logger.info('OpenAI Realtime Voice Agent initialized');


// ---- STRICT VOICE GLUE (auto TTS helper) ----
import { speak, summaryFromStrictResponse } from './tts.js';
import { registerTtsStart } from './antiCancelClient.js';

async function speakStrictSummary(resp){
  const text = summaryFromStrictResponse(resp);
  await registerTtsStart();
  speak(text);
  return text;
}

window.strictVoiceAgent = Object.assign(window.strictVoiceAgent || {}, {
  speakStrictSummary
});
// ---- END STRICT VOICE GLUE ----
