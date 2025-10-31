export const handler = async (event) => {
    const request = event.Records[0].cf.request;
    const ga4ghMatch = request.uri.match(/^(?:\/training-material)?\/api\/ga4gh\/(?<path>.*)/);
    if (ga4ghMatch) {
        request.uri = `/training-material/api/ga4gh/${ga4ghMatch.groups.path}.json`;
    } else if (request.uri.startsWith('/.well-known/webfinger')) {
        request.uri = '/training-material/api/fedi/' + request.querystring + '.json';
    } else if (!request.uri.startsWith('/training-material/')) {
        request.uri = request.uri.replace(/^\//, '/training-material/');
    }
    console.log("DEBUG: final request URI is: " + request.uri)
    return request;
};
