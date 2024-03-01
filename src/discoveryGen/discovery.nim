## https://developers.google.com/discovery/v1/reference/apis

import std/options
import std/tables

type
  DiscoveryIcons* = object
    x16*: Option[string]
      ## The URL of the 16x16 icon.
    x32*: Option[string]
      ## The URL of the 32x32 icon.

  DiscoveryEndpoint* = object
    endpointUrl*: string
      ## The URL of the endpoint target host.
    location*: string
      ## The location of the endpoint.
    description*: string
      ## A string describing the host designated by the URL.
    deprecated*: bool
      ## Whether this endpoint is deprecated.

  DiscoveryAnnotations* = object
    required*: seq[string]
      ## A list of methods that require this property on requests.

  DiscoveryJsonSchema* = ref object
    ## An individual schema description.
    id*: string
      ## Unique identifier for this schema.
    `type`*: string
      ## The value type for this schema. A list of values can be found at the
      ## `"type" section in the JSON Schema
      ## <https://datatracker.ietf.org/doc/html/draft-zyp-json-schema-03#section-5.1>`.
    `$ref`*: Option[string]
      ## A reference to another schema. The value of this property is the ID of another schema.
    description*: string
      ## A description of this object.
    default*: Option[string]
      ## The default value of this property (if one exists).
    required*: bool
      ## Whether the parameter is required.
    format*: Option[string]
      ## An additional regular expression or key that helps constrain the value. For more details
      ## see the `Type and Format Summary <https://developers.google.com/discovery/v1/type-format>`.
    pattern*: Option[string]
      ## The regular expression this parameter must conform to.
    minimum*: Option[string]
      ## The minimum value of this parameter.
    maximum*: Option[string]
      ## The minimum value of this parameter.
    `enum`*: Option[seq[string]]
      ## Values this parameter may take (if it is an enum).
    enumDescriptions*: Option[seq[string]]
      ## The descriptions for the enums. Each position maps to the corresponding value in the enum
      ## array.
    repeated*: bool
      ## Whether this parameter may appear multiple times.
    location*: string
      ## Whether this parameter goes in the query or the path for REST requests.
    properties*: Table[string, DiscoveryJsonSchema]
      ## If this is a schema for an object, list the schema for each property of this object.
    items*: Option[DiscoveryJsonSchema]
      ## If this is a schema for an array, this property is the schema for each element in
      ## the array.
    annotations*: Option[DiscoveryAnnotations]
      ## Additional information about this property.

  DiscoveryOAuth2Scope* = object
    ## The scope value.
    description*: string
      ## Description of scope.

  DiscoveryOAuth2* = object
    scopes*: Table[string, DiscoveryOAuth2Scope]
      ## Available OAuth 2.0 scopes.

  DiscoveryAuth* = object
    oauth2*: DiscoveryOAuth2
      ## OAuth 2.0 authentication information.

  DiscoveryMediaUploadProtocol* = object
    multipart*: bool
      ## `true` if this endpoint supports upload multipart media.
    path*: string
      ## The URI path to be used for upload. Should be used in conjunction with the `rootURL`
      ## property at the api-level.

  DiscoveryMediaUploadProtocols* = object
    simple*: Option[DiscoveryMediaUploadProtocol]
      ## Supports uploading as a single HTTP request.
    resumable*: Option[DiscoveryMediaUploadProtocol]
      ## Supports the Resumable Media Upload protocol.

  DiscoveryMediaUpload* = object
    accept*: seq[string]
      ## MIME Media Ranges for acceptable media uploads to this method.
    maxSize*: Option[string]
      ## Maximum size of a media upload, such as "1MB", "2GB" or "3TB".
    protocols*: DiscoveryMediaUploadProtocols
      ## Supported upload protocols.

  DiscoveryRequest* = object
    `$ref`*: string
      ## Schema ID for the request schema.
    # parameterName*: string
    #   ## [DEPRECATED] Some APIs have this field for backward-compatibility reasons. It can be
    #   ## safely ignored.

  DiscoveryResponse* = object
    `$ref`*: string
      ## Schema ID for the response schema.

  DiscoveryRestMethod* = object
    ## An individual method description.
    id*: string
      ## A unique ID for this method. This property can be used to match methods between different
      ## versions of Discovery.
    description*: string
      ## Description of this method.
    deprecated*: bool
      ## Whether this method is deprecated.
    parameters*: Table[string, DiscoveryJsonSchema]
      ## Details for all parameters in this method.
    parameterOrder*: seq[string]
      ## Ordered list of required parameters. This serves as a hint to clients on how to structure
      ## their method signatures. The array is ordered such that the most significant parameter
      ## appears first.
    scopes*: seq[string]
      ## OAuth 2.0 scopes applicable to this method.
    supportsMediaDownload*: bool
      ## Whether this method supports media downloads.
    supportsMediaUpload*: bool
      ## Whether this method supports media uploads.
    mediaUpload*: Option[DiscoveryMediaUpload]
      ## Media upload parameters.
    supportsSubscription*: bool
      ## Whether this method supports subscriptions.
    path*: string
      ## The URI path of this REST method. Should be used in conjunction with the `servicePath`
      ## property at the API-level.
    flatPath*: Option[string]
      ## The URI path of this REST method in (RFC 6570) format without level 2 features ({+var}).
      ## Supplementary to the `path` property.
    httpMethod*: string
      ## HTTP method used by this method.
    request*: DiscoveryRequest
      ## The schema for the request.
    response*: DiscoveryResponse
      ## The schema for the response.

  DiscoveryRestResource* = object
    ## An individual resource description. Contains methods and sub-resources related to this
    ## resource.
    methods*: Table[string, DiscoveryRestMethod]
      ## Methods on this resource.
    deprecated*: bool
      ## Whether this resource is deprecated.
    resources*: Table[string, DiscoveryRestResource]
      ## Sub-resources on this resource.

  DiscoveryRestDescription* = object
    # kind*: string
    #   ## The kind for this response. The fixed string `discovery#restDescription`.
    discoveryVersion*: string
      ## Indicate the version of the Discovery API used to generate this doc.
    id*: string
      ## The ID of the Discovery document for the API. For example, urlshortener:v1.
    name*: string
      ## The name of the API. For example, urlshortener.
    canonicalName*: string
      ## The canonical name of the API. For example, Url Shortener.
    version*: string
      ## The version of the API. For example, v1.
    revision*: string
      ## The revision of the API.
    title*: string
      ## The title of the API. For example, "Google Url Shortener API".
    description*: string
      ## The description of this API.
    icons*: DiscoveryIcons
      ## Links to 16x16 and 32x32 icons representing the API.
    documentationLink*: Option[string]
      ## A link to human-readable documentation for the API.
    labels*: seq[string]
      ## Labels for the status of this API. Valid values include `limited_availability` or
      ## `deprecated`.
    protocol*: string
      ## The protocol described by the document. For example, `rest`.
    rootUrl*: string
      ## The root url under which all API services live.
    endpoints*: seq[DiscoveryEndpoint]
      ## A list of location-based endpoint objects for this API. Each object contains the endpoint
      ## URL, location, description and deprecation status.
    parameters*: Table[string, DiscoveryJsonSchema]
      ## Common parameters that apply across all apis.
    auth*: DiscoveryAuth
      ## Authentication information.
    features*: seq[string]
      ## A list of supported features for this API.
    schemas*: Table[string, DiscoveryJsonSchema]
      ## The schemas for this API.
    methods*: Table[string, DiscoveryRestMethod]
      ## API-level methods for this API.
    # baseUrl*: string
    #   ## [DEPRECATED] The base URL for REST requests.
    # basePath*: string
    #   ## [DEPRECATED] The base path for REST requests.
    servicePath*: string
      ## The base path for all REST requests.
    batchPath*: string
      ## The path for REST batch requests.
    resources*: Table[string, DiscoveryRestResource]
      ## The resources in this API.
