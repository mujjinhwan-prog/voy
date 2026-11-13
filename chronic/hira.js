// api/hira.js  —  Vercel Function (Node.js) · 심평원 Open API 중계
// 인증키는 Vercel 환경변수 DATA_GO_KR_KEY 에만 저장되고 브라우저에는 노출되지 않습니다.
// ※ 공공데이터 API는 해외 IP를 차단할 수 있으므로
//    Vercel → Settings → Functions → Function Region 을 "Seoul (icn1)" 로 지정하세요.
//
// 호출 예) /api/hira?svc=basis&sidoCd=110000&dgsbjtCd=01&pageNo=1
//         /api/hira?svc=top5&ykiho=...   (질병 Top5)
//         /api/hira?svc=dtl&ykiho=...    (진료시간)
//         /api/hira?svc=spc&ykiho=...    (과목별 전문의)
//         /api/hira?svc=asm&ykiho=...    (병원평가 등급)
//         /api/hira?svc=pharm&sidoCd=..&sgguCd=..  (약국 위치)
//         /api/hira?svc=ping   → 실행 지역·사용 주소 확인 (진단용)
//         /api/hira?svc=config → 지도용 브이월드 키 (Vercel 환경변수 VWORLD_KEY)
// API 주소가 바뀌면 코드 수정 없이 Vercel 환경변수로 덮어쓸 수 있습니다.
//   BASIS_URL = 병원정보서비스 병원기본목록 요청주소
//   TOP5_URL  = 병원진료정보조회서비스 의원진료상위질병5개 요청주소
//   DTL_URL   = 의료기관별상세정보서비스 세부정보 요청주소
//   SPC_URL   = 의료기관별상세정보서비스 전문과목별 전문의수 요청주소
//   ASM_URL   = 병원평가정보서비스 요청주소
//   PHARM_URL = 약국정보서비스 약국기본목록 요청주소

const SERVICES = {
  basis: {
    url: process.env.BASIS_URL || "https://apis.data.go.kr/B551182/hospInfoServicev2/getHospBasisList",
    params: ["pageNo", "numOfRows", "sidoCd", "sgguCd", "emdongNm", "clCd", "dgsbjtCd", "yadmNm"],
    ttl: 86400, // 기관 목록: 하루 캐시
  },
  top5: {
    url: process.env.TOP5_URL || "https://apis.data.go.kr/B551182/hospDiagInfoService1/getClinicTop5List1",
    params: ["ykiho"],
    ttl: 604800, // 상위질병: 일주일 캐시 (1년치 집계라 자주 안 바뀜)
  },
  asm: {   // 병원평가정보서비스 > 병원평가상세등급조회 (고혈압·당뇨 asmGrd24, COPD asmGrd17, 천식 asmGrd16 …)
    url: process.env.ASM_URL || "https://apis.data.go.kr/B551182/hospAsmInfoService1/getHospAsmInfo1",
    params: ["ykiho", "pageNo", "numOfRows"],
    ttl: 604800,
  },
  pharm: { // 약국정보서비스 > 약국기본목록 (문전약국 계산용 좌표)
    url: process.env.PHARM_URL || "https://apis.data.go.kr/B551182/pharmacyInfoService/getParmacyBasisList",
    params: ["pageNo", "numOfRows", "sidoCd", "sgguCd", "emdongNm"],
    ttl: 604800,
  },
  dtl: {   // 의료기관별상세정보서비스 > 세부정보 (진료시간)
    url: process.env.DTL_URL || "https://apis.data.go.kr/B551182/MadmDtlInfoService2.8/getDtlInfo2.8",
    params: ["ykiho"],
    ttl: 604800,
  },
  spc: {   // 의료기관별상세정보서비스 > 전문과목별 전문의 수
    url: process.env.SPC_URL || "https://apis.data.go.kr/B551182/MadmDtlInfoService2.8/getSpcSbjtSdrInfo2.8",
    params: ["ykiho"],
    ttl: 604800,
  },
};

const ALLOWED = (process.env.ALLOWED_ORIGIN || "").split(",").map(s => s.trim()).filter(Boolean);

function cors(origin) {
  const ok = !ALLOWED.length || ALLOWED.includes(origin);
  return {
    "Access-Control-Allow-Origin": ok ? origin || "*" : "null",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    Vary: "Origin",
  };
}

// <item>…</item> 블록을 {태그: 값} 객체 배열로 변환
function parseXml(xml) {
  const text = (s) => s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").trim();
  const pick = (tag) => { const m = xml.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`)); return m ? text(m[1]) : ""; };
  const items = [];
  for (const m of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const o = {};
    for (const f of m[1].matchAll(/<([A-Za-z0-9_]+)>([\s\S]*?)<\/\1>/g)) o[f[1]] = text(f[2]);
    items.push(o);
  }
  return {
    resultCode: pick("resultCode") || pick("returnReasonCode"),
    resultMsg: pick("resultMsg") || pick("returnAuthMsg") || pick("errMsg"),
    totalCount: Number(pick("totalCount") || 0),
    items,
  };
}

const json = (obj, status, headers) => new Response(JSON.stringify(obj), { status, headers });

export function OPTIONS(req) {
  return new Response(null, { status: 204, headers: cors(req.headers.get("origin") || "") });
}

export async function GET(req) {
  const origin = req.headers.get("origin") || "";
  const headers = { ...cors(origin), "Content-Type": "application/json; charset=utf-8" };
  const q = new URL(req.url).searchParams;

  if (q.get("svc") === "ping") {
    return json({
      region: process.env.VERCEL_REGION || "unknown", // icn1 이면 서울
      keySet: !!process.env.DATA_GO_KR_KEY,
      basis: SERVICES.basis.url,
      top5: SERVICES.top5.url,
      dtl: SERVICES.dtl.url,
      spc: SERVICES.spc.url,
      asm: SERVICES.asm.url,
      pharm: SERVICES.pharm.url,
    }, 200, headers);
  }

  if (q.get("svc") === "config") {   // 화면에서 쓰는 공개 설정 (브이월드 키는 등록 도메인에서만 동작하는 브라우저용 키)
    return json({ vworldKey: process.env.VWORLD_KEY || "" }, 200, { ...headers, "Cache-Control": "public, s-maxage=3600" });
  }

  const svc = SERVICES[q.get("svc")];
  if (!svc) return json({ error: "svc는 basis, top5, dtl, spc, asm, pharm, ping, config 중 하나" }, 400, headers);

  let key = process.env.DATA_GO_KR_KEY || "";
  if (!key) return json({ error: "Vercel 환경변수 DATA_GO_KR_KEY가 없습니다." }, 500, headers);
  if (key.includes("%")) key = decodeURIComponent(key); // Encoding 키를 넣어도 동작하도록

  const up = new URL(svc.url);
  up.searchParams.set("serviceKey", key);
  for (const p of svc.params) if (q.get(p)) up.searchParams.set(p, q.get(p));
  if (!up.searchParams.get("pageNo")) up.searchParams.set("pageNo", "1");
  if (!up.searchParams.get("numOfRows")) up.searchParams.set("numOfRows", "10");

  try {
    const r = await fetch(up.toString(), { headers: { Accept: "application/xml" } });
    const body = await r.text();
    const data = parseXml(body);
    const ok = r.ok && (!data.resultCode || data.resultCode === "00" || data.resultCode === "0000");
    if (!ok) {
      return json({
        error: data.resultMsg || `HTTP ${r.status}`, code: data.resultCode,
        region: process.env.VERCEL_REGION || "unknown", url: svc.url, raw: body.slice(0, 300),
      }, 502, headers);
    }
    return new Response(JSON.stringify(data), {
      status: 200,
      headers: { ...headers, "Cache-Control": `public, s-maxage=${svc.ttl}, stale-while-revalidate=86400` },
    });
  } catch (e) {
    return json({ error: String(e), region: process.env.VERCEL_REGION || "unknown" }, 502, headers);
  }
}
