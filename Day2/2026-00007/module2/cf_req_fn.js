import cf from 'cloudfront';

const kvsHandle = cf.kvs();

async function handler(event) {
  var request = event.request;
  var cookies = request.cookies;

  var weightStr = await kvsHandle.get('weight');
  var weight = parseFloat(weightStr);
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
