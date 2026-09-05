// Synthetic browser gateway: no Electron, real library, credentials or model calls.
async function fixture(page) {
  await page.addInitScript(() => {
    const ok = data => Promise.resolve({ ok: true, data });
    const now = '2026-09-05T04:00:00.000Z';
    const settings = { version: 1, providerId: 'openai', modelId: 'alpha-1', accuracyMode: 'high', scenarioId: null, customPrompt: '', resolve: { fieldFormats: { scene: 'XXX', shot: 'XX', take: 'XX' }, comments: { goodTake: '_OK', holdTake: '_KP' } } };
    const projects = [0,1,2].map(i => ({ id: 'project-review-' + i, name: i === 0 ? '审查样例项目' : '纪录片项目 ' + i, description: '仅用于 UI 审查的模拟数据', relativePath: 'projects/review-' + i, archivedAt: null, createdAt: now, updatedAt: now, taskCount: 0, latestTaskAt: null, canArchive: true, settings: structuredClone(settings), lastRecognitionDefaults: null }));
    const models = ['openai','openrouter'].flatMap((p, i) => [1,2,3].map(n => ({ id: (i ? 'beta-' : 'alpha-') + n, label: (i ? 'Beta 模型 ' : 'Alpha 模型 ') + n, providers: [p], vendor: i ? 'beta' : 'openai', fixed: true, capabilityStatus: 'declared' })));
    const config = { providers: [{id:'openai',label:'OpenAI',configured:true,requiredEnv:['OPENAI_API_KEY']},{id:'openrouter',label:'OpenRouter',configured:true,requiredEnv:['OPENROUTER_API_KEY']}], models, upload: { acceptedTypes:['image/jpeg','image/png','image/webp','application/pdf'],maxBytes:20971520,maxRequestBytes:83886080,maxPages:20 }, workflow: { resolve: settings.resolve, slate: {maxDirectoryDepth:4} }, ocrEngines: [{id:'vision', label:'Apple Vision OCR', enabled:true,available:true,required:false,mode:'auto',language:'zh-Hans',recognitionLevel:'accurate'},{id:'paddleocr',label:'PaddleOCR',enabled:true,available:true,required:false,mode:'auto',modelVersion:'PP-OCRv5',profile:'balanced',profileLabel:'平衡'}], ocrSelection: {id:'vision',label:'Apple Vision OCR',mode:'auto',reason:'自动模式优先 Vision OCR。',available:true,enabled:true,required:false} };
    const globalSettings = { values: { MAX_BODY_MB:'80', MODEL_REQUEST_TIMEOUT_MS:'120000', MODEL_REQUEST_MAX_RETRIES:'2', MODEL_PAGE_CONCURRENCY:'2', MAX_CONCURRENT_RECOGNITIONS:'1', VISIONOCR_ENABLED:'auto',VISIONOCR_REQUIRED:'false',PADDLEOCR_ENABLED:'auto',PADDLEOCR_REQUIRED:'false',PADDLEOCR_PROFILE:'balanced',PADDLEOCR_MODEL_VERSION:'PP-OCRv5',OPENAI_BASE_URL:'https://api.openai.com/v1',OPENROUTER_BASE_URL:'https://openrouter.ai/api/v1'},overrides:[],keyConfigured:{openai:true,openrouter:true},restartRequired:false };
    const tasks = new Map();
    window.__review = { config, projects, models, globalSettings, tasks, calls: [], createMode:'success', modelDelay:{} };
    window.slateSync = {
      app: {getConfig:()=>ok(config)},
      projects: {
        getLibraryInfo:()=>ok({id:'review-library',name:'隔离审查库',path:'/tmp/slatesync-ui-review-library',projectCount:projects.length}),
        list:()=>ok(projects), load:({id})=>ok(projects.find(p=>p.id===id)), listScenarios:()=>ok([]),
        create:async data=>{window.__review.calls.push(['create',data]); if(window.__review.createMode==='failure') return {ok:false,error:{code:'TEST_FAILURE',message:'模拟：项目创建失败，请重试',retryable:true}}; const project={...structuredClone(projects[0]),...data,id:'project-created-'+Date.now()};projects.push(project);return ok(project);},
        update:async data=>{window.__review.calls.push(['update',data]);const p=projects.find(p=>p.id===data.id);Object.assign(p,data);return ok(structuredClone(p));},
        archive:({id})=>{const p=projects.find(p=>p.id===id);p.archivedAt=now;return ok(structuredClone(p));},restore:({id})=>{const p=projects.find(p=>p.id===id);p.archivedAt=null;return ok(structuredClone(p));}
      },
      recognition: {onProgress:()=>()=>{},getModels:async({providerId})=>{const snapshot=models.filter(m=>m.providers.includes(providerId));await new Promise(r=>setTimeout(r,window.__review.modelDelay[providerId]||0));return ok({models:snapshot,source:'static',pendingModels:[],unsupportedModels:[]});}},
      tasks: {list:()=>ok([]),save:({task})=>{const id=task.id||'review-task';tasks.set(id,structuredClone({...task,id}));return ok(id);},load:({id})=>ok(tasks.get(id))},
      settings: {getGlobalSettings:()=>ok(globalSettings),getOcrSettings:()=>ok({pythonPath:'',setupCompleted:true,setupSkipped:false}),saveGlobalSettings:async patch=>{Object.assign(globalSettings.values,patch.values);return ok(structuredClone(globalSettings));},listCustomProviders:()=>ok([]),onPaddleOcrInstallProgress:()=>()=>{},onModelProbeProgress:()=>()=>{}},
      logs: {read:()=>ok({entries:[],hasMore:false})}
    };
  });
}

module.exports = { fixture };
