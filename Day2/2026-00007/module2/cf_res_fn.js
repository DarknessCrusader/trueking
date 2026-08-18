async function handler(event) {
  var response = event.response;
  var request = event.request;

  if (request.headers['x-sp-ab-assigned']) {
    var assigned = request.headers['x-sp-ab-assigned'].value;
    response.cookies['x-sp-ab'] = {
      value: assigned,
      attributes: 'Path=/; Max-Age=86400'
    };
  }

  return response;
}
