import cf from 'cloudfront';

const kvsId = 'PLACEHOLDER_KVS_ID';
const kvsHandle = cf.kvs(kvsId);

async function handler(event) {
  var request = event.request;
  var cookies = request.cookies;

  var weight = parseFloat(await kvsHandle.get('weight'));
  var versionA = await kvsHandle.get('version_a');
  var versionB = await kvsHandle.get('version_b');

  if (cookies['x-sp-ab']) {
    var variant = cookies['x-sp-ab'].value;
    request.uri = variant === 'b' ? versionB : versionA;
  } else {
    var assigned = Math.random() < weight ? 'b' : 'a';
    request.uri = assigned === 'b' ? versionB : versionA;
    request.headers['x-sp-ab-assigned'] = { value: assigned };
  }

  return request;
}
