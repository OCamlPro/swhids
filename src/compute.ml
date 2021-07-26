open Lang

let hexdigest_from_git_object git_object =
  Digestif.SHA1.to_hex @@ Digestif.SHA1.digest_string git_object

let git_object_header fmt (git_type, len) =
  match git_type with
  | "blob"
  | "commit"
  | "extid"
  | "raw_extrinsic_metadata"
  | "snapshot"
  | "tag"
  | "tree" ->
    Format.fprintf fmt "%s %d\x00" git_type len
  | git_type ->
    Utils.error
      (Format.sprintf "invalid git object type `%s` (Compute.git_object_header)"
         git_type )

let escape_newlines snippet =
  String.concat "\n " (String.split_on_char '\n' snippet)

let format_git_object_from_headers fmt (git_type, headers, message) =
  let entries = Buffer.create 512 in

  let buff_fmt = Format.formatter_of_buffer entries in

  Array.iter
    (fun (k, v) -> Format.fprintf buff_fmt "%s %s@." k (escape_newlines v))
    headers;

  begin
    match message with
    | None -> ()
    | Some message -> Format.fprintf buff_fmt "%s" message
  end;

  Format.pp_print_flush buff_fmt ();

  let entries = Buffer.contents entries in

  Format.fprintf fmt "%a%s" git_object_header
    (git_type, String.length entries)
    entries

let format_author fmt author = Format.fprintf fmt "%s" author

let normalize_timestamp = function
  | None -> None
  | Some time_representation ->
    let seconds, microseconds, offset, negative_utc = time_representation in
    Some ((seconds, microseconds), offset, negative_utc)

let format_date fmt (seconds, microseconds) =
  match microseconds with
  | 0 -> Format.fprintf fmt "%d" seconds
  | microseconds ->
    (* TODO: this should be the equivalent of:
     * float_value = "%d.%06d" % (seconds, microseconds)
     * return float_value.rstrip("0").encode()
     * *)
    Format.fprintf fmt "%d.%06d" seconds microseconds

let format_offset fmt (offset, negative_utc) =
  let sign =
    if offset < 0 || (offset = 0 && negative_utc) then
      "-"
    else
      "+"
  in
  let offset = Int.abs offset in
  let hours = offset / 60 in
  let minutes = offset mod 60 in
  Format.fprintf fmt "%s%02d%02d" sign hours minutes

let format_author_data fmt (author, date_offset) =
  Format.fprintf fmt "%a" format_author author;
  let date_offset = normalize_timestamp date_offset in
  match date_offset with
  | None -> ()
  | Some (timestamp, offset, negative_utc) ->
    Format.fprintf fmt " %a %a" format_date timestamp format_offset
      (offset, negative_utc)

let content_identifier content =
  (* Quoting SWH documentation:
   * for contents, the intrinsic identifier is the sha1_git hash returned by
   * swh.model.identifiers.content_identifier(), i.e., the SHA1 of a byte sequence
   * obtained by juxtaposing the ASCII string "blob" (without quotes), a space, the
   * length of the content as decimal digits, a NULL byte, and the actual content
   * of the file. *)
  let object_type = target_type_to_git Content in
  let len = String.length content in
  let git_object =
    Format.asprintf "%a%s" git_object_header (object_type, len) content
  in
  let hexdigest = hexdigest_from_git_object git_object in
  let object_id =
    match object_id_from_string hexdigest with
    | None -> Utils.error "invalid hexdigest (content_identifier)"
    | Some object_id -> object_id
  in
  ((1, Content, object_id), [])

let directory_identifier _d = ((1, Directory, [||]), [])

let target_invalid target = String.length target <> 40

let release_identifier target target_type name author date message =
  if target_invalid target then Utils.error "target must be of length 40";
  let git_object =
    let headers =
      [| ("object", target)
       ; ("type", target_type_to_git target_type)
       ; ("tag", name)
      |]
    in
    let headers =
      match author with
      | None -> headers
      | Some author ->
        Array.append headers
          [| ("tagger", Format.asprintf "%a" format_author_data (author, date))
          |]
    in
    Format.asprintf "%a" format_git_object_from_headers ("tag", headers, message)
  in
  let hexdigest = hexdigest_from_git_object git_object in
  let object_id =
    match object_id_from_string hexdigest with
    | None -> Utils.error "invalid hexdigest (content_identifier)"
    | Some object_id -> object_id
  in
  ((1, Release, object_id), [])

let revision_identifier directory parents author author_date committer
    committer_date extra_headers message =
  if List.exists target_invalid (directory :: parents) then
    Utils.error "target (directory and parents) must be of length 40";

  (* TODO: this is probably false :-) *)
  let rec pp_parents fmt = function
    | [] -> ()
    | parent :: parents ->
      Format.fprintf fmt "%s" parent;
      pp_parents fmt parents
  in

  let git_object =
    let headers = [| ("tree", directory) |] in
    let headers =
      match parents with
      | [] -> headers
      | parents ->
        Array.append headers
          [| ("parent", Format.asprintf "%a" pp_parents parents) |]
    in
    let headers =
      match author with
      | None -> headers
      | Some author ->
        Array.append headers
          [| ( "author"
             , Format.asprintf "%a" format_author_data (author, author_date) )
          |]
    in
    let headers =
      match committer with
      | None -> headers
      | Some committer ->
        Array.append headers
          [| ( "committer"
             , Format.asprintf "%a" format_author_data
                 (committer, committer_date) )
          |]
    in
    let headers = Array.append headers extra_headers in

    let message =
      match message with
      | None -> None
      | Some msg -> Some (Format.sprintf "@.%s" msg)
    in

    Format.asprintf "%a" format_git_object_from_headers
      ("commit", headers, message)
  in

  let hexdigest = hexdigest_from_git_object git_object in
  let object_id =
    match object_id_from_string hexdigest with
    | None -> Utils.error "invalid hexdigest (content_identifier)"
    | Some object_id -> object_id
  in

  ((1, Revision, object_id), [])

let snapshot_identifier _s = ((1, Snapshot, [||]), [])
