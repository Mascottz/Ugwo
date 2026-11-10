module Main exposing (main)

import Browser
import Char
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onClick, onInput, onSubmit)
import Http
import Json.Decode as D
import Svg
import Svg.Attributes as SA


main : Program String Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        , view = view
        }



-- DOMAIN TYPES


type Tab
    = OverviewTab
    | SubscriptionsTab
    | ProjectsTab
    | AttributionTab
    | FiscalTab
    | EcosystemTab


type CatalogCurrency
    = CurNGN
    | CurKES
    | CurGHS
    | CurZAR
    | CurXOF
    | CurUSD


type ModalState
    = NoModal
    | NewSubModal SubForm
    | NewProjectModal ProjectForm
    | NewLeadModal LeadForm
    | ClientPortalModal AgencyProject
    | EventInspectModal OutboxEvent
    | FlowMationPackModal String


type alias SubForm =
    { company : String
    , contact : String
    , phone : String
    , country : String
    , currency : String
    , planId : String
    , tin : String
    }


type alias ProjectForm =
    { title : String
    , company : String
    , contact : String
    , phone : String
    , currency : String
    , subtotalMajor : String
    , whtBps : String
    , revCap : String
    , deliverable : String
    }


type alias LeadForm =
    { platform : String
    , campaign : String
    , creative : String
    , buyer : String
    , phone : String
    , currency : String
    , amountMajor : String
    , firstMsg : String
    }


type alias Workspace =
    { slug : String
    , name : String
    , sellerTin : String
    , govOutage : Bool
    , senviokSender : String
    , flowmationUrl : String
    , apiKey : String
    }


type alias RuntimeInfo =
    { gateway : String
    , kernel : String
    , ui : String
    , supervisedOps : Int
    , lastOp : String
    }


type alias LedgerItem =
    { currency : String
    , decimals : Int
    , amountMinor : Int
    , formatted : String
    }


type alias PlanItem =
    { id : String
    , name : String
    , kind : String
    , interval : String
    , ngnFmt : String
    , kesFmt : String
    , ghsFmt : String
    , zarFmt : String
    , xofFmt : String
    , usdFmt : String
    , includedUnits : Int
    , includedCredits : Int
    , railsLabel : String
    }


type alias SubscriptionItem =
    { id : String
    , planId : String
    , customerName : String
    , customerCompany : String
    , customerPhone : String
    , currency : String
    , amountFormatted : String
    , railDetail : String
    , status : String
    , unitsLimit : Int
    , unitsUsed : Int
    , monthlyCreditsLeft : Int
    , rolloverCredits : Int
    , dunningStage : String
    , portalToken : String
    }


type alias DeliverableItem =
    { id : String
    , title : String
    , preview : String
    , downloadUrl : String
    }


type alias AgencyProject =
    { id : String
    , title : String
    , clientName : String
    , clientCompany : String
    , clientPhone : String
    , currency : String
    , grossFormatted : String
    , whtFormatted : String
    , netCashFormatted : String
    , cashPaidFormatted : String
    , remainingFormatted : String
    , extraRevFormatted : String
    , whtCertStatus : String
    , paymentRail : String
    , portalToken : String
    , whtRateBps : Int
    , remainingMinor : Int
    , revisionsIncluded : Int
    , revisionsUsed : Int
    , vaultUnlocked : Bool
    , deliverables : List DeliverableItem
    }


type alias AdLead =
    { id : String
    , platform : String
    , campaignName : String
    , creativeName : String
    , clickId : String
    , spendFormatted : String
    , customerName : String
    , customerPhone : String
    , firstMsg : String
    , currency : String
    , expectedFormatted : String
    , paymentRail : String
    , capiStatus : String
    , capiEventId : String
    , spendMinor : Int
    , verifiedMinor : Int
    , fakeBlocked : Int
    }


type alias FiscalInvoice =
    { id : String
    , invoiceNumber : String
    , sourceKind : String
    , buyerName : String
    , buyerTin : String
    , authority : String
    , subtotalFormatted : String
    , vatFormatted : String
    , whtFormatted : String
    , payableFormatted : String
    , fiscalStatus : String
    , irnOrCu : String
    , csidHash : String
    , qrPayload : String
    , retryCount : Int
    , errorDetail : String
    }


type alias OutboxEvent =
    { id : String
    , target : String
    , eventType : String
    , destination : String
    , status : String
    , creditsUsed : Int
    , signatureHeader : String
    , payloadJson : String
    , createdAt : String
    }


type alias Snapshot =
    { workspace : Workspace
    , ledger : List LedgerItem
    , plans : List PlanItem
    , subscriptions : List SubscriptionItem
    , projects : List AgencyProject
    , leads : List AdLead
    , invoices : List FiscalInvoice
    , events : List OutboxEvent
    }


type alias ApiEnvelope =
    { notice : String
    , snapshot : Snapshot
    , runtime : RuntimeInfo
    }


type alias Model =
    { activeTab : Tab
    , catalogCur : CatalogCurrency
    , notice : String
    , snapshot : Maybe Snapshot
    , runtime : Maybe RuntimeInfo
    , modal : ModalState
    , loading : Bool
    }


tabFromHash : String -> Tab
tabFromHash h =
    case h of
        "#subscriptions" ->
            SubscriptionsTab

        "#milestones" ->
            ProjectsTab

        "#attribution" ->
            AttributionTab

        "#tax" ->
            FiscalTab

        "#integrations" ->
            EcosystemTab

        _ ->
            OverviewTab


init : String -> ( Model, Cmd Msg )
init initialHash =
    ( { activeTab = tabFromHash initialHash
      , catalogCur = CurNGN
      , notice = ""
      , snapshot = Nothing
      , runtime = Nothing
      , modal = NoModal
      , loading = True
      }
    , fetchState
    )



-- MESSAGES & UPDATE


type Msg
    = SwitchTab Tab
    | SwitchCurrency CatalogCurrency
    | ClearNotice
    | CloseModal
    | OpenNewSubModal
    | UpdateSubForm (SubForm -> SubForm)
    | SubmitNewSub
    | OpenNewProjectModal
    | UpdateProjectForm (ProjectForm -> ProjectForm)
    | SubmitNewProject
    | OpenNewLeadModal
    | UpdateLeadForm (LeadForm -> LeadForm)
    | SubmitNewLead
    | OpenPortalModal AgencyProject
    | OpenEventModal OutboxEvent
    | RequestFlowMationPack
    | GotFlowMationPack (Result Http.Error String)
    | RunAction String String
    | GotEnvelope (Result Http.Error ApiEnvelope)


fetchState : Cmd Msg
fetchState =
    Http.get
        { url = "/api/state"
        , expect = Http.expectJson GotEnvelope envelopeDecoder
        }


postAction : String -> String -> Cmd Msg
postAction path bodyStr =
    Http.post
        { url = path
        , body = Http.stringBody "text/plain; charset=utf-8" bodyStr
        , expect = Http.expectJson GotEnvelope envelopeDecoder
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        SwitchTab t ->
            ( { model | activeTab = t }, Cmd.none )

        SwitchCurrency c ->
            ( { model | catalogCur = c }, Cmd.none )

        ClearNotice ->
            ( { model | notice = "" }, Cmd.none )

        CloseModal ->
            ( { model | modal = NoModal }, Cmd.none )

        OpenNewSubModal ->
            ( { model
                | modal =
                    NewSubModal
                        { company = "Paystack Merchant Labs"
                        , contact = "Zainab Ibrahim"
                        , phone = "08051129834"
                        , country = "NG"
                        , currency = "NGN"
                        , planId = "plan_growth"
                        , tin = "TIN-88392019-0001"
                        }
              }
            , Cmd.none
            )

        UpdateSubForm fn ->
            case model.modal of
                NewSubModal f ->
                    ( { model | modal = NewSubModal (fn f) }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SubmitNewSub ->
            case model.modal of
                NewSubModal f ->
                    let
                        arg =
                            String.join "|"
                                [ sanitizePipe f.company
                                , sanitizePipe f.contact
                                , sanitizePipe f.phone
                                , sanitizePipe f.country
                                , sanitizePipe f.currency
                                , sanitizePipe f.planId
                                , sanitizePipe f.tin
                                ]
                    in
                    ( { model | modal = NoModal, loading = True }
                    , postAction "/api/subscriptions/create" arg
                    )

                _ ->
                    ( model, Cmd.none )

        OpenNewProjectModal ->
            ( { model
                | modal =
                    NewProjectModal
                        { title = "E-Commerce Replatform & Meta CAPI Funnel"
                        , company = "Zuri Retail Group"
                        , contact = "Adebayo Ogunlesi"
                        , phone = "08062219044"
                        , currency = "NGN"
                        , subtotalMajor = "1200000"
                        , whtBps = "500"
                        , revCap = "2"
                        , deliverable = "Figma Master System + Production Storefront Repo"
                        }
              }
            , Cmd.none
            )

        UpdateProjectForm fn ->
            case model.modal of
                NewProjectModal f ->
                    ( { model | modal = NewProjectModal (fn f) }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SubmitNewProject ->
            case model.modal of
                NewProjectModal f ->
                    let
                        arg =
                            String.join "|"
                                [ sanitizePipe f.title
                                , sanitizePipe f.company
                                , sanitizePipe f.contact
                                , sanitizePipe f.phone
                                , sanitizePipe f.currency
                                , sanitizePipe f.subtotalMajor
                                , sanitizePipe f.whtBps
                                , sanitizePipe f.revCap
                                , sanitizePipe f.deliverable
                                ]
                    in
                    ( { model | modal = NoModal, loading = True }
                    , postAction "/api/projects/create" arg
                    )

                _ ->
                    ( model, Cmd.none )

        OpenNewLeadModal ->
            ( { model
                | modal =
                    NewLeadModal
                        { platform = "meta_ctwa"
                        , campaign = "Lagos_SME_Solar_Inverter_Q4"
                        , creative = "Reel_04_NoGenNoise_PidginHook"
                        , buyer = "Ngozi Eze"
                        , phone = "08037719200"
                        , currency = "NGN"
                        , amountMajor = "650000"
                        , firstMsg = "Saw your IG Reel; send transfer account for the 2.5kVA office kit."
                        }
              }
            , Cmd.none
            )

        UpdateLeadForm fn ->
            case model.modal of
                NewLeadModal f ->
                    ( { model | modal = NewLeadModal (fn f) }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SubmitNewLead ->
            case model.modal of
                NewLeadModal f ->
                    let
                        arg =
                            String.join "|"
                                [ sanitizePipe f.platform
                                , sanitizePipe f.campaign
                                , sanitizePipe f.creative
                                , sanitizePipe f.buyer
                                , sanitizePipe f.phone
                                , sanitizePipe f.currency
                                , sanitizePipe f.amountMajor
                                , sanitizePipe f.firstMsg
                                ]
                    in
                    ( { model | modal = NoModal, loading = True }
                    , postAction "/api/attribution/create" arg
                    )

                _ ->
                    ( model, Cmd.none )

        OpenPortalModal proj ->
            ( { model | modal = ClientPortalModal proj }, Cmd.none )

        OpenEventModal ev ->
            ( { model | modal = EventInspectModal ev }, Cmd.none )

        RequestFlowMationPack ->
            ( model
            , Http.get
                { url = "/api/ecosystem/flowmation-pack.json"
                , expect = Http.expectString GotFlowMationPack
                }
            )

        GotFlowMationPack res ->
            case res of
                Ok packJson ->
                    ( { model | modal = FlowMationPackModal packJson }, Cmd.none )

                Err _ ->
                    ( { model | notice = "Could not load FlowMation pack preview." }, Cmd.none )

        RunAction endpoint arg ->
            ( { model | loading = True, modal = NoModal }
            , postAction endpoint arg
            )

        GotEnvelope res ->
            case res of
                Ok env ->
                    let
                        nextNotice =
                            if env.notice == "State synchronized." && model.notice == "" then
                                ""

                            else
                                env.notice
                    in
                    ( { model
                        | snapshot = Just env.snapshot
                        , runtime = Just env.runtime
                        , notice = nextNotice
                        , loading = False
                      }
                    , Cmd.none
                    )

                Err _ ->
                    ( { model | loading = False, notice = "Connection warning: retry operation." }
                    , Cmd.none
                    )


sanitizePipe : String -> String
sanitizePipe s =
    String.replace "|" " " (String.trim s)



-- FORMATTING HELPERS


formatIntCommas : Int -> String
formatIntCommas n =
    let
        raw =
            String.fromInt (Basics.abs n)

        revGroups s acc =
            if String.length s <= 3 then
                s :: acc

            else
                revGroups (String.dropRight 3 s) (String.right 3 s :: acc)

        joined =
            String.join "," (revGroups raw [])
    in
    if n < 0 then
        "-" ++ joined

    else
        joined


humanWhtStatus : String -> String
humanWhtStatus raw =
    case raw of
        "verified" ->
            "Credit note verified"

        "pending_cert" ->
            "Certificate pending"

        _ ->
            "No WHT"


humanDunningStage : String -> String
humanDunningStage raw =
    case raw of
        "d_plus_3_whatsapp" ->
            "Overdue · 3D"

        "d_0_due" ->
            "Due today"

        "recovered" ->
            "Recovered"

        _ ->
            "Overdue"


humanPlatform : String -> String
humanPlatform raw =
    case raw of
        "meta_ctwa" ->
            "Meta WhatsApp"

        "tiktok_messaging" ->
            "TikTok Ads"

        _ ->
            raw


humanSourceKind : String -> String
humanSourceKind raw =
    case raw of
        "subscription" ->
            "Subscription"

        "agency_milestone" ->
            "Milestone"

        "ad_commerce" ->
            "Ad Commerce"

        _ ->
            raw


humanTaxId : String -> String
humanTaxId raw =
    if String.startsWith "TIN" raw then
        raw

    else
        "PIN " ++ raw


humanAuthority : String -> String
humanAuthority raw =
    case raw of
        "FIRS_MBS_NG" ->
            "Nigeria FIRS"

        "KRA_ETIMS_KE" ->
            "Kenya eTIMS"

        _ ->
            raw


humanChannel : String -> String
humanChannel raw =
    case raw of
        "flowmation_webhook" ->
            "FlowMation Webhook"

        "senviok_whatsapp" ->
            "Senviok WhatsApp"

        _ ->
            raw


humanEventTitle : String -> String
humanEventTitle raw =
    case raw of
        "subscription.whatsapp_dunning" ->
            "WhatsApp renewal reminder"

        "dunning.scheduled_followup" ->
            "Scheduled WhatsApp follow-up"

        "dunning.auto_cancel_on_settlement" ->
            "Dunning cancelled upon payment"

        "subscription.renewed" ->
            "Subscription renewal settled"

        "credits.topup.settled" ->
            "Rollover credit pack added"

        "agency.milestone.unlocked" ->
            "Client milestone settled and vault unlocked"

        "scope.extra_revision.quoted" ->
            "Out-of-scope revision quote sent"

        "attribution.purchase.verified" ->
            "Verified purchase sent to Meta CAPI"

        _ ->
            raw



-- REUSABLE TYPOGRAPHIC STATUS MARK (NO GENERIC BUBBLES)


statusMark : String -> String -> Html Msg
statusMark tone labelText =
    span [ class ("status-mark " ++ tone) ]
        [ span [ class "mark-glyph" ] []
        , span [] [ text labelText ]
        ]



-- JSON DECODERS


req : String -> D.Decoder a -> D.Decoder (a -> b) -> D.Decoder b
req key valDec fnDec =
    D.map2 (|>) (D.field key valDec) fnDec


envelopeDecoder : D.Decoder ApiEnvelope
envelopeDecoder =
    D.map3 ApiEnvelope
        (D.field "notice" D.string)
        (D.field "snapshot" snapshotDecoder)
        (D.field "runtime" runtimeDecoder)


runtimeDecoder : D.Decoder RuntimeInfo
runtimeDecoder =
    D.map5 RuntimeInfo
        (D.field "gateway" D.string)
        (D.field "kernel" D.string)
        (D.field "ui" D.string)
        (D.field "supervised_ops" D.int)
        (D.field "last_op" D.string)


snapshotDecoder : D.Decoder Snapshot
snapshotDecoder =
    D.map8 Snapshot
        (D.field "workspace" workspaceDecoder)
        (D.field "ledger" (D.list ledgerDecoder))
        (D.field "plans" (D.list planDecoder))
        (D.field "subscriptions" (D.list subDecoder))
        (D.field "projects" (D.list projectDecoder))
        (D.field "leads" (D.list leadDecoder))
        (D.field "invoices" (D.list invoiceDecoder))
        (D.field "events" (D.list eventDecoder))


workspaceDecoder : D.Decoder Workspace
workspaceDecoder =
    D.map7 Workspace
        (D.field "slug" D.string)
        (D.field "name" D.string)
        (D.field "seller_tin" D.string)
        (D.field "gov_portal_outage_sim" D.bool)
        (D.field "senviok_sender_id" D.string)
        (D.field "flowmation_hook_url" D.string)
        (D.field "api_key" D.string)


ledgerDecoder : D.Decoder LedgerItem
ledgerDecoder =
    D.map4 LedgerItem
        (D.field "currency" D.string)
        (D.field "decimals" D.int)
        (D.field "amount_minor" D.int)
        (D.field "formatted" D.string)


planDecoder : D.Decoder PlanItem
planDecoder =
    D.succeed PlanItem
        |> req "id" D.string
        |> req "name" D.string
        |> req "kind" D.string
        |> req "billing_interval" D.string
        |> req "ngn_fmt" D.string
        |> req "kes_fmt" D.string
        |> req "ghs_fmt" D.string
        |> req "zar_fmt" D.string
        |> req "xof_fmt" D.string
        |> req "usd_fmt" D.string
        |> req "included_units" D.int
        |> req "included_credits" D.int
        |> req "rails_label" D.string


subDecoder : D.Decoder SubscriptionItem
subDecoder =
    D.succeed SubscriptionItem
        |> req "id" D.string
        |> req "plan_id" D.string
        |> req "customer_name" D.string
        |> req "customer_company" D.string
        |> req "customer_phone" D.string
        |> req "currency" D.string
        |> req "amount_formatted" D.string
        |> req "rail_detail" D.string
        |> req "status" D.string
        |> req "units_limit" D.int
        |> req "units_used" D.int
        |> req "monthly_credits_left" D.int
        |> req "rollover_credits" D.int
        |> req "dunning_stage" D.string
        |> req "portal_token" D.string


deliverableDecoder : D.Decoder DeliverableItem
deliverableDecoder =
    D.map4 DeliverableItem
        (D.field "id" D.string)
        (D.field "title" D.string)
        (D.field "preview" D.string)
        (D.field "download_url" D.string)


projectDecoder : D.Decoder AgencyProject
projectDecoder =
    D.succeed AgencyProject
        |> req "id" D.string
        |> req "title" D.string
        |> req "client_name" D.string
        |> req "client_company" D.string
        |> req "client_phone" D.string
        |> req "currency" D.string
        |> req "gross_formatted" D.string
        |> req "wht_formatted" D.string
        |> req "net_cash_formatted" D.string
        |> req "cash_paid_formatted" D.string
        |> req "remaining_formatted" D.string
        |> req "extra_rev_formatted" D.string
        |> req "wht_cert_status" D.string
        |> req "payment_rail" D.string
        |> req "portal_token" D.string
        |> req "wht_rate_bps" D.int
        |> req "remaining_minor" D.int
        |> req "revisions_included" D.int
        |> req "revisions_used" D.int
        |> req "vault_unlocked" D.bool
        |> req "deliverables" (D.list deliverableDecoder)


leadDecoder : D.Decoder AdLead
leadDecoder =
    D.succeed AdLead
        |> req "id" D.string
        |> req "platform" D.string
        |> req "campaign_name" D.string
        |> req "creative_name" D.string
        |> req "click_id" D.string
        |> req "spend_formatted" D.string
        |> req "customer_name" D.string
        |> req "customer_phone" D.string
        |> req "whatsapp_first_msg" D.string
        |> req "currency" D.string
        |> req "expected_formatted" D.string
        |> req "payment_rail" D.string
        |> req "capi_status" D.string
        |> req "capi_event_id" D.string
        |> req "spend_minor" D.int
        |> req "verified_minor" D.int
        |> req "fake_blocked" D.int


invoiceDecoder : D.Decoder FiscalInvoice
invoiceDecoder =
    D.succeed FiscalInvoice
        |> req "id" D.string
        |> req "invoice_number" D.string
        |> req "source_kind" D.string
        |> req "buyer_name" D.string
        |> req "buyer_tin" D.string
        |> req "authority" D.string
        |> req "subtotal_formatted" D.string
        |> req "vat_formatted" D.string
        |> req "wht_formatted" D.string
        |> req "payable_formatted" D.string
        |> req "fiscal_status" D.string
        |> req "irn_or_cu" D.string
        |> req "csid_hash" D.string
        |> req "qr_payload" D.string
        |> req "retry_count" D.int
        |> req "error_detail" D.string


eventDecoder : D.Decoder OutboxEvent
eventDecoder =
    D.succeed OutboxEvent
        |> req "id" D.string
        |> req "target" D.string
        |> req "event_type" D.string
        |> req "destination" D.string
        |> req "status" D.string
        |> req "credits_used" D.int
        |> req "signature_header" D.string
        |> req "payload_json" D.string
        |> req "created_at" D.string



-- VIEW SHELL


view : Model -> Html Msg
view model =
    div []
        [ viewMasthead model
        , main_ [ class "ledger-page" ]
            [ viewNotice model.notice
            , case model.snapshot of
                Nothing ->
                    div [ class "ledger-section", style "padding" "24px" ]
                        [ text "Synchronizing Ụgwọ ledger..." ]

                Just snap ->
                    viewActiveTab model snap
            ]
        , viewModal model.modal
        ]


viewMasthead : Model -> Html Msg
viewMasthead model =
    let
        outage =
            case model.snapshot of
                Nothing ->
                    False

                Just s ->
                    s.workspace.govOutage

        tabBtn tab labelText =
            button
                [ class
                    (if model.activeTab == tab then
                        "tab-link active"

                     else
                        "tab-link"
                    )
                , onClick (SwitchTab tab)
                ]
                [ text labelText ]
    in
    header [ class "masthead" ]
        [ div [ class "masthead-inner" ]
            [ div [ class "masthead-left" ]
                [ div [ class "brand-seal" ]
                    [ span [ class "seal-wordmark" ] [ text "Ụgwọ" ]
                    ]
                , nav [ class "masthead-nav" ]
                    [ tabBtn OverviewTab "Overview"
                    , tabBtn SubscriptionsTab "Subscriptions"
                    , tabBtn ProjectsTab "Milestones"
                    , tabBtn AttributionTab "Attribution"
                    , tabBtn FiscalTab "Tax & Filing"
                    , tabBtn EcosystemTab "Integrations"
                    ]
                ]
            , div [ class "masthead-status" ]
                [ span
                    [ class
                        (if outage then
                            "ink-square amber"

                         else
                            "ink-square"
                        )
                    ]
                    []
                , span []
                    [ text
                        (if outage then
                            "Tax Portal 504 Queue"

                         else
                            "FIRS & eTIMS Live"
                        )
                    ]
                ]
            ]
        ]


viewNotice : String -> Html Msg
viewNotice msg =
    if msg == "" then
        text ""

    else
        div [ class "notice-tape" ]
            [ span [] [ text msg ]
            , button
                [ class "btn btn-sm"
                , style "background" "transparent"
                , style "border-color" "rgba(255,255,255,0.28)"
                , style "color" "#fbf9f6"
                , onClick ClearNotice
                ]
                [ text "Dismiss" ]
            ]


viewActiveTab : Model -> Snapshot -> Html Msg
viewActiveTab model snap =
    case model.activeTab of
        OverviewTab ->
            viewOverview snap

        SubscriptionsTab ->
            viewSubscriptions model.catalogCur snap

        ProjectsTab ->
            viewProjects snap

        AttributionTab ->
            viewAttribution snap

        FiscalTab ->
            viewFiscal snap

        EcosystemTab ->
            viewEcosystem snap



-- 1. OVERVIEW


viewOverview : Snapshot -> Html Msg
viewOverview snap =
    let
        pastDueSubs =
            List.filter (\s -> s.status /= "active") snap.subscriptions

        unpaidProjects =
            List.filter (\p -> p.remainingMinor > 0) snap.projects

        pendingLeads =
            List.filter (\l -> l.capiStatus /= "capi_purchase_fired") snap.leads

        queuedInvoices =
            List.filter (\i -> i.fiscalStatus == "queued_gov_outage") snap.invoices

        openTotal =
            List.length pastDueSubs
                + List.length unpaidProjects
                + List.length pendingLeads
                + List.length queuedInvoices
    in
    div []
        [ div [ class "editorial-head" ]
            [ div []
                [ div [ class "editorial-kicker" ] [ text "Consolidated Ledger" ]
                , h1 [ class "editorial-title" ] [ text "Revenue & Settlement" ]
                , p [ class "editorial-sub" ]
                    [ text "Verified local-currency volume across bank transfers, mobile money, client milestones, and tax clearance." ]
                ]
            , div [ class "head-controls" ]
                [ button [ class "btn", onClick RequestFlowMationPack ] [ text "Export FlowMation Pack" ]
                , button [ class "btn btn-primary", onClick OpenNewProjectModal ] [ text "New Milestone" ]
                ]
            ]
        , div [ class "figure-strip" ]
            (List.map
                (\item ->
                    div [ class "figure-cell" ]
                        [ div [ class "figure-kicker" ] [ text (item.currency ++ " Settled") ]
                        , div [ class "figure-num" ] [ text item.formatted ]
                        , div [ class "figure-caption" ]
                            [ text
                                (if item.decimals == 0 then
                                    "0-decimal integer ledger"

                                 else
                                    "Verified local rail settlement"
                                )
                            ]
                        ]
                )
                (List.take 3 snap.ledger)
                ++ [ div [ class "figure-cell" ]
                        [ div [ class "figure-kicker" ] [ text "Open Queue" ]
                        , div [ class "figure-num" ] [ text (String.fromInt openTotal) ]
                        , div [ class "figure-caption" ] [ text "Items awaiting collection or verification" ]
                        ]
                   ]
            )
        , div [ class "ledger-section wine-top" ]
            [ div [ class "section-bar" ]
                [ h2 [ class "section-heading" ] [ text "Collection & Verification Queue" ]
                , span [ class "section-note tabular" ] [ text (String.fromInt openTotal ++ " pending") ]
                ]
            , if openTotal == 0 then
                div [ style "padding" "22px 20px", style "color" "var(--ink-mid)" ]
                    [ text "All subscriptions, client milestones, ad settlements, and tax clearances are up to date." ]

              else
                div [ class "entry-list" ]
                    (List.map
                        (\proj ->
                            div [ class "entry-row" ]
                                [ div [ class "entry-primary" ]
                                    [ div [ class "entry-serial" ] [ text ("MILESTONE · " ++ String.toUpper proj.clientCompany) ]
                                    , div [ class "entry-title" ] [ text proj.title ]
                                    , div [ class "entry-sub" ] [ text "Raw deliverables remain watermarked until cash balance clears." ]
                                    ]
                                , div [ class "entry-figures" ]
                                    [ div [ class "entry-amount" ] [ text proj.remainingFormatted ]
                                    , div [ class "entry-breakdown" ] [ text ("WHT " ++ proj.whtFormatted) ]
                                    ]
                                , div [ class "entry-tail" ]
                                    [ statusMark "hold" "Vault Locked"
                                    , button [ class "btn btn-sm btn-primary", onClick (RunAction "/api/projects/settle" proj.id) ]
                                        [ text "Collect" ]
                                    ]
                                ]
                        )
                        unpaidProjects
                        ++ List.map
                            (\sub ->
                                div [ class "entry-row" ]
                                    [ div [ class "entry-primary" ]
                                        [ div [ class "entry-serial" ] [ text ("SUBSCRIPTION · " ++ sub.currency) ]
                                        , div [ class "entry-title" ] [ text sub.customerCompany ]
                                        , div [ class "entry-sub" ] [ text sub.railDetail ]
                                        ]
                                    , div [ class "entry-figures" ]
                                        [ div [ class "entry-amount" ] [ text sub.amountFormatted ]
                                        , div [ class "entry-breakdown" ] [ text "Monthly renewal" ]
                                        ]
                                    , div [ class "entry-tail" ]
                                        [ statusMark "hold" (humanDunningStage sub.dunningStage)
                                        , button [ class "btn btn-sm", onClick (RunAction "/api/subscriptions/dunning" sub.id) ]
                                            [ text "Remind" ]
                                        , button [ class "btn btn-sm btn-primary", onClick (RunAction "/api/subscriptions/settle" sub.id) ]
                                            [ text "Settle" ]
                                        ]
                                    ]
                            )
                            pastDueSubs
                        ++ List.map
                            (\lead ->
                                div [ class "entry-row" ]
                                    [ div [ class "entry-primary" ]
                                        [ div [ class "entry-serial" ] [ text (String.toUpper (humanPlatform lead.platform)) ]
                                        , div [ class "entry-title" ] [ text lead.customerName ]
                                        , div [ class "entry-sub" ] [ text lead.campaignName ]
                                        ]
                                    , div [ class "entry-figures" ]
                                        [ div [ class "entry-amount" ] [ text lead.expectedFormatted ]
                                        , div [ class "entry-breakdown" ] [ text lead.paymentRail ]
                                        ]
                                    , div [ class "entry-tail" ]
                                        [ statusMark "hold" "Pixel Hold"
                                        , button [ class "btn btn-sm btn-primary", onClick (RunAction "/api/attribution/verify" lead.id) ]
                                            [ text "Confirm" ]
                                        ]
                                    ]
                            )
                            pendingLeads
                        ++ (if List.isEmpty queuedInvoices then
                                []

                            else
                                [ div [ class "entry-row two-col" ]
                                    [ div [ class "entry-primary" ]
                                        [ div [ class "entry-serial" ] [ text "TAX CLEARANCE BUFFER" ]
                                        , div [ class "entry-title" ]
                                            [ text (String.fromInt (List.length queuedInvoices) ++ " invoice(s) held during government portal 504 timeout") ]
                                        , div [ class "entry-sub" ]
                                            [ text "Buyer checkouts completed without interruption; ready to transmit for stamping." ]
                                        ]
                                    , div [ class "entry-tail" ]
                                        [ button [ class "btn btn-sm btn-primary", onClick (RunAction "/api/fiscal/flush" "") ]
                                            [ text "Transmit & Stamp" ]
                                        ]
                                    ]
                                ]
                           )
                    )
            ]
        , div [ class "ledger-section" ]
            [ div [ class "section-bar" ]
                [ h2 [ class "section-heading" ] [ text "Recent Ledger Dispatches" ]
                , button [ class "btn btn-sm btn-quiet", onClick (SwitchTab EcosystemTab) ] [ text "Full log →" ]
                ]
            , div [ class "entry-list" ]
                (List.map
                    (\ev ->
                        div [ class "entry-row two-col" ]
                            [ div [ class "entry-primary" ]
                                [ div [ class "entry-title" ] [ text (humanEventTitle ev.eventType) ]
                                , div [ class "entry-sub" ] [ text (humanChannel ev.target ++ " → " ++ ev.destination) ]
                                ]
                            , div [ class "entry-tail" ]
                                [ if ev.status == "suppressed_stop_on_paid" then
                                    statusMark "wine" "Stop-on-Paid · 0 Cr"

                                  else
                                    statusMark "settled" "Dispatched"
                                , button [ class "btn btn-sm btn-quiet", onClick (OpenEventModal ev) ] [ text "Inspect" ]
                                ]
                            ]
                    )
                    (List.take 5 snap.events)
                )
            ]
        ]



-- 2. SUBSCRIPTIONS


planPriceFor : CatalogCurrency -> PlanItem -> String
planPriceFor cur plan =
    case cur of
        CurNGN ->
            plan.ngnFmt

        CurKES ->
            plan.kesFmt

        CurGHS ->
            plan.ghsFmt

        CurZAR ->
            plan.zarFmt

        CurXOF ->
            plan.xofFmt

        CurUSD ->
            plan.usdFmt


viewSubscriptions : CatalogCurrency -> Snapshot -> Html Msg
viewSubscriptions cur snap =
    let
        curBtn c code =
            button
                [ class
                    (if cur == c then
                        "cur-btn active"

                     else
                        "cur-btn"
                    )
                , onClick (SwitchCurrency c)
                ]
                [ text code ]
    in
    div []
        [ div [ class "editorial-head" ]
            [ div []
                [ div [ class "editorial-kicker" ] [ text "Recurring Revenue & Metering" ]
                , h1 [ class "editorial-title" ] [ text "Subscriptions & Rollover Credits" ]
                , p [ class "editorial-sub" ]
                    [ text "Local-currency tariffs, non-expiring credit packs, and Stop-on-Paid WhatsApp renewals." ]
                ]
            , div [ class "head-controls" ]
                [ div [ class "currency-switcher" ]
                    [ curBtn CurNGN "NGN"
                    , curBtn CurKES "KES"
                    , curBtn CurGHS "GHS"
                    , curBtn CurZAR "ZAR"
                    , curBtn CurXOF "XOF"
                    , curBtn CurUSD "USD"
                    ]
                , button [ class "btn btn-primary", onClick OpenNewSubModal ] [ text "New Subscriber" ]
                ]
            ]
        , div [ class "figure-strip cols-3" ]
            (List.map
                (\plan ->
                    div [ class "figure-cell" ]
                        [ div [ class "figure-kicker" ]
                            [ text
                                (plan.name
                                    ++ (if plan.interval == "one_time" then
                                            " · One-Time"

                                        else
                                            " · Monthly"
                                       )
                                )
                            ]
                        , div [ class "figure-num" ] [ text (planPriceFor cur plan) ]
                        , div [ class "figure-caption tabular" ]
                            [ text
                                (if plan.kind == "credit_pack" then
                                    formatIntCommas plan.includedCredits ++ " non-expiring rollover credits"

                                 else
                                    formatIntCommas plan.includedUnits ++ " units · " ++ formatIntCommas plan.includedCredits ++ " credits"
                                )
                            ]
                        ]
                )
                snap.plans
            )
        , div [ class "ledger-section" ]
            [ div [ class "section-bar" ]
                [ h2 [ class "section-heading" ] [ text "Subscriber Accounts" ]
                , span [ class "section-note" ] [ text "Monthly allowance burns first; rollover packs never expire." ]
                ]
            , div [ class "entry-list" ]
                (List.map viewSubEntry snap.subscriptions)
            ]
        ]


viewSubEntry : SubscriptionItem -> Html Msg
viewSubEntry s =
    let
        pct =
            Basics.min 100 ((s.unitsUsed * 100) // Basics.max 1 s.unitsLimit)
    in
    div [ class "entry-row" ]
        [ div [ class "entry-primary" ]
            [ div [ class "entry-serial" ] [ text (s.currency ++ " · " ++ s.customerPhone) ]
            , div [ class "entry-title" ] [ text s.customerCompany ]
            , div [ class "entry-sub" ] [ text (s.customerName ++ " · " ++ s.railDetail) ]
            ]
        , div [ class "entry-figures" ]
            [ div [ class "entry-amount" ] [ text (s.amountFormatted ++ "/mo") ]
            , div [ class "entry-breakdown" ]
                [ text (formatIntCommas s.monthlyCreditsLeft ++ " mo · " ++ formatIntCommas s.rolloverCredits ++ " rollover cr") ]
            , div [ style "display" "inline-block" ]
                [ div [ class "quota-rule" ]
                    [ div [ class "quota-fill", style "width" (String.fromInt pct ++ "%") ] [] ]
                ]
            ]
        , div [ class "entry-tail" ]
            [ if s.status == "active" then
                statusMark "settled" "Active"

              else
                statusMark "hold" (humanDunningStage s.dunningStage)
            , button [ class "btn btn-sm btn-quiet", onClick (RunAction "/api/subscriptions/consume" s.id) ]
                [ text "Meter 250" ]
            , button [ class "btn btn-sm btn-quiet", onClick (RunAction "/api/subscriptions/topup" s.id) ]
                [ text "+2,500 Cr" ]
            , if s.status == "active" then
                button [ class "btn btn-sm", onClick (RunAction "/api/subscriptions/dunning" s.id) ]
                    [ text "Send Reminder" ]

              else
                button [ class "btn btn-sm btn-primary", onClick (RunAction "/api/subscriptions/settle" s.id) ]
                    [ text "Settle" ]
            ]
        ]



-- 3. MILESTONES & CLIENT VAULT


viewProjects : Snapshot -> Html Msg
viewProjects snap =
    div []
        ([ div [ class "editorial-head" ]
            [ div []
                [ div [ class "editorial-kicker" ] [ text "Scope Protection & Escrow Vault" ]
                , h1 [ class "editorial-title" ] [ text "Milestones & WHT Vouchers" ]
                , p [ class "editorial-sub" ]
                    [ text "Enforce revision caps, account for Withholding Tax credit notes, and release raw files only upon settlement." ]
                ]
            , div [ class "head-controls" ]
                [ button [ class "btn btn-primary", onClick OpenNewProjectModal ] [ text "New Milestone" ] ]
            ]
         ]
            ++ List.map viewMilestoneVoucher snap.projects
        )


viewMilestoneVoucher : AgencyProject -> Html Msg
viewMilestoneVoucher proj =
    let
        atCap =
            proj.revisionsUsed >= proj.revisionsIncluded

        whtPct =
            String.fromInt (proj.whtRateBps // 100) ++ "%"
    in
    div [ class "ledger-section wine-top" ]
        [ div [ class "voucher-head" ]
            [ div []
                [ div [ class "entry-serial" ] [ text (String.toUpper proj.clientCompany ++ " · " ++ proj.clientName) ]
                , h2 [ class "serif", style "margin" "2px 0 0", style "font-size" "20px", style "font-weight" "700" ]
                    [ text proj.title ]
                , div [ class "entry-sub" ] [ text (proj.paymentRail ++ " · " ++ proj.clientPhone) ]
                ]
            , div [ style "padding-top" "4px" ]
                [ if proj.vaultUnlocked then
                    statusMark "settled" "Settled · Vault Open"

                  else
                    statusMark "hold" (proj.remainingFormatted ++ " Balance Due")
                ]
            ]
        , div [ class "voucher-strip" ]
            [ div [ class "voucher-cell" ]
                [ div [ class "figure-kicker" ] [ text "Invoice Gross" ]
                , div [ class "figure-num", style "font-size" "18px" ] [ text proj.grossFormatted ]
                , div [ class "figure-caption" ] [ text "Includes statutory VAT" ]
                ]
            , div [ class "voucher-cell" ]
                [ div [ class "figure-kicker" ] [ text (whtPct ++ " WHT Credit") ]
                , div [ class "figure-num", style "font-size" "18px" ] [ text proj.whtFormatted ]
                , div [ class "figure-caption" ] [ text (humanWhtStatus proj.whtCertStatus) ]
                ]
            , div [ class "voucher-cell" ]
                [ div [ class "figure-kicker" ] [ text "Net Cash Paid" ]
                , div [ class "figure-num", style "font-size" "18px" ] [ text proj.cashPaidFormatted ]
                , div [ class "figure-caption tabular" ] [ text ("of " ++ proj.netCashFormatted ++ " collectible") ]
                ]
            , div [ class "voucher-cell" ]
                [ div [ class "figure-kicker" ] [ text "Revisions Used" ]
                , div [ class "figure-num", style "font-size" "18px" ]
                    [ text (String.fromInt proj.revisionsUsed ++ " / " ++ String.fromInt proj.revisionsIncluded) ]
                , div [ class "figure-caption tabular" ] [ text ("+" ++ proj.extraRevFormatted ++ " per extra") ]
                ]
            ]
        , div [ class "entry-list" ]
            (List.map
                (\d ->
                    div [ class "entry-row two-col" ]
                        [ div [ class "entry-primary" ]
                            [ div [ class "entry-title" ] [ text d.title ]
                            , div [ class "entry-sub" ]
                                [ if proj.vaultUnlocked then
                                    span [ class "mono", style "color" "var(--ink-settled)" ] [ text d.downloadUrl ]

                                  else
                                    text d.preview
                                ]
                            ]
                        , div [ class "entry-tail" ]
                            [ if proj.vaultUnlocked then
                                statusMark "settled" "Unlocked"

                              else
                                statusMark "hold" "Watermarked"
                            ]
                        ]
                )
                proj.deliverables
            )
        , div [ class "voucher-foot" ]
            [ div [ style "display" "flex", style "gap" "8px", style "flex-wrap" "wrap" ]
                [ button [ class "btn btn-sm", onClick (OpenPortalModal proj) ]
                    [ text "Client Portal View" ]
                , button [ class "btn btn-sm", onClick (RunAction "/api/projects/revision" proj.id) ]
                    [ text
                        (if atCap then
                            "Quote Extra Revision (+" ++ proj.extraRevFormatted ++ ")"

                         else
                            "Record Revision"
                        )
                    ]
                ]
            , div []
                [ if proj.remainingMinor > 0 then
                    button [ class "btn btn-sm btn-primary", onClick (RunAction "/api/projects/settle" proj.id) ]
                        [ text ("Settle " ++ proj.remainingFormatted) ]

                  else
                    span [ class "mono", style "color" "var(--ink-faint)" ]
                        [ text "VOUCHER CLOSED" ]
                ]
            ]
        ]



-- 4. ATTRIBUTION


viewAttribution : Snapshot -> Html Msg
viewAttribution snap =
    let
        capiSent =
            List.length (List.filter (\l -> l.capiStatus == "capi_purchase_fired") snap.leads)

        heldCount =
            List.length snap.leads - capiSent

        fakeCount =
            List.sum (List.map .fakeBlocked snap.leads)
    in
    div []
        [ div [ class "editorial-head" ]
            [ div []
                [ div [ class "editorial-kicker" ] [ text "Click-to-WhatsApp Revenue Proof" ]
                , h1 [ class "editorial-title" ] [ text "Ad Attribution & Fraud Shield" ]
                , p [ class "editorial-sub" ]
                    [ text "Hold Meta CAPI and TikTok purchase events until bank or M-Pesa transfers settle on the ledger." ]
                ]
            , div [ class "head-controls" ]
                [ button [ class "btn btn-primary", onClick OpenNewLeadModal ] [ text "Log Ad Lead" ] ]
            ]
        , div [ class "figure-strip cols-3" ]
            [ div [ class "figure-cell" ]
                [ div [ class "figure-kicker" ] [ text "Verified CAPI Events" ]
                , div [ class "figure-num" ] [ text (String.fromInt capiSent) ]
                , div [ class "figure-caption" ] [ text "Dispatched after verified settlement" ]
                ]
            , div [ class "figure-cell" ]
                [ div [ class "figure-kicker" ] [ text "Held Pending Cash" ]
                , div [ class "figure-num" ] [ text (String.fromInt heldCount) ]
                , div [ class "figure-caption" ] [ text "Awaiting transfer or STK confirmation" ]
                ]
            , div [ class "figure-cell" ]
                [ div [ class "figure-kicker" ] [ text "Fake Alerts Rejected" ]
                , div [ class "figure-num" ] [ text (String.fromInt fakeCount) ]
                , div [ class "figure-caption" ] [ text "Blocked unverified receipt screenshots" ]
                ]
            ]
        , div [ class "ledger-section" ]
            [ div [ class "section-bar" ]
                [ h2 [ class "section-heading" ] [ text "Attributed WhatsApp Threads" ]
                , span [ class "section-note" ] [ text "Deduplicated click IDs bound to E.164 phone numbers." ]
                ]
            , div [ class "entry-list" ]
                (List.map viewLeadEntry snap.leads)
            ]
        ]


viewLeadEntry : AdLead -> Html Msg
viewLeadEntry lead =
    let
        settled =
            lead.capiStatus == "capi_purchase_fired"
    in
    div [ class "entry-row" ]
        [ div [ class "entry-primary" ]
            [ div [ class "entry-serial" ]
                [ text (String.toUpper (humanPlatform lead.platform) ++ " · " ++ lead.creativeName) ]
            , div [ class "entry-title" ] [ text (lead.customerName ++ " · " ++ lead.customerPhone) ]
            , div [ class "entry-sub" ] [ text ("\"" ++ lead.firstMsg ++ "\"") ]
            ]
        , div [ class "entry-figures" ]
            [ div [ class "entry-amount" ] [ text lead.expectedFormatted ]
            , div [ class "entry-breakdown" ] [ text lead.paymentRail ]
            ]
        , div [ class "entry-tail" ]
            [ if settled then
                div [ style "text-align" "right" ]
                    [ statusMark "settled" "CAPI Sent"
                    , div [ class "mono", style "color" "var(--ink-faint)", style "margin-top" "2px" ]
                        [ text lead.capiEventId ]
                    ]

              else
                div [ style "display" "flex", style "align-items" "center", style "gap" "8px", style "flex-wrap" "wrap" ]
                    [ if lead.fakeBlocked > 0 then
                        statusMark "alert" (String.fromInt lead.fakeBlocked ++ " Fake Rejected")

                      else
                        statusMark "hold" "Pixel Hold"
                    , button [ class "btn btn-sm btn-alert", onClick (RunAction "/api/attribution/fake" lead.id) ]
                        [ text "Reject Fake" ]
                    , button [ class "btn btn-sm btn-primary", onClick (RunAction "/api/attribution/verify" lead.id) ]
                        [ text "Verify Cash" ]
                    ]
            ]
        ]



-- 5. TAX & FISCAL FILING (SOVEREIGN DOUBLE-RULED STAMPS, NO GENERIC BOXES)


viewFiscal : Snapshot -> Html Msg
viewFiscal snap =
    let
        outage =
            snap.workspace.govOutage

        queuedCount =
            List.length (List.filter (\i -> i.fiscalStatus == "queued_gov_outage") snap.invoices)
    in
    div []
        [ div [ class "editorial-head" ]
            [ div []
                [ div [ class "editorial-kicker" ] [ text ("Seller TIN " ++ snap.workspace.sellerTin) ]
                , h1 [ class "editorial-title" ] [ text "Tax & Fiscal Clearance" ]
                , p [ class "editorial-sub" ]
                    [ text "Nigeria FIRS MBS and Kenya KRA eTIMS cryptographic clearance with non-blocking 504 outage buffering." ]
                ]
            , div [ class "head-controls" ]
                [ button
                    [ class
                        (if outage then
                            "btn btn-alert"

                         else
                            "btn"
                        )
                    , onClick (RunAction "/api/fiscal/toggle-outage" "")
                    ]
                    [ text
                        (if outage then
                            "Portal 504 Sim: ACTIVE"

                         else
                            "Simulate 504 Outage"
                        )
                    ]
                , if queuedCount > 0 then
                    button [ class "btn btn-primary", onClick (RunAction "/api/fiscal/flush" "") ]
                        [ text ("Transmit " ++ String.fromInt queuedCount ++ " Buffered") ]

                  else
                    text ""
                ]
            ]
        , div [ class "ledger-section wine-top" ]
            [ div [ class "section-bar" ]
                [ h2 [ class "section-heading" ] [ text "Fiscal Voucher Register" ]
                , span [ class "section-note" ]
                    [ text "Upstream government timeouts buffer locally so buyer checkouts never fail." ]
                ]
            , div [ class "entry-list" ]
                (List.map viewFiscalEntry snap.invoices)
            ]
        ]


viewFiscalEntry : FiscalInvoice -> Html Msg
viewFiscalEntry inv =
    div [ class "entry-row" ]
        [ div [ class "entry-primary" ]
            [ div [ class "entry-serial" ]
                [ text (inv.invoiceNumber ++ " · " ++ String.toUpper (humanSourceKind inv.sourceKind)) ]
            , div [ class "entry-title" ] [ text inv.buyerName ]
            , div [ class "entry-sub mono" ]
                [ text (humanAuthority inv.authority ++ " · " ++ humanTaxId inv.buyerTin) ]
            ]
        , div [ class "entry-figures" ]
            [ div [ class "entry-amount" ] [ text inv.payableFormatted ]
            , div [ class "entry-breakdown" ]
                [ text ("Sub " ++ inv.subtotalFormatted ++ " · VAT " ++ inv.vatFormatted) ]
            , if inv.whtFormatted /= "₦0.00" && inv.whtFormatted /= "KSh 0.00" && inv.whtFormatted /= "CFA 0" then
                div [ class "entry-breakdown" ] [ text ("WHT " ++ inv.whtFormatted) ]

              else
                text ""
            ]
        , div [ class "entry-tail" ]
            [ if inv.fiscalStatus == "stamped" then
                div [ class "fiscal-stamp" ]
                    [ viewQrMatrix inv.qrPayload
                    , div [ class "fiscal-stamp-meta" ]
                        [ div [ class "fiscal-stamp-head" ]
                            [ text (humanAuthority inv.authority ++ " · Fiscal Seal") ]
                        , div [ class "fiscal-stamp-irn" ] [ text inv.irnOrCu ]
                        , div [ class "fiscal-stamp-csid" ] [ text inv.csidHash ]
                        ]
                    ]

              else if inv.fiscalStatus == "queued_gov_outage" then
                div [ class "fiscal-hold-stamp" ]
                    [ statusMark "hold" ("Buffered · 504 Retry #" ++ String.fromInt inv.retryCount)
                    , div [ class "mono", style "font-size" "10.5px", style "color" "var(--ink-faint)", style "margin-top" "3px" ]
                        [ text "Checkout completed; awaiting portal" ]
                    ]

              else
                statusMark "alert" "Missing Buyer TIN"
            ]
        ]


viewQrMatrix : String -> Html Msg
viewQrMatrix seed =
    let
        seedSum =
            List.foldl (\ch acc -> modBy 65521 (acc * 31 + Char.toCode ch)) 7 (String.toList seed)

        coords =
            List.concatMap
                (\y -> List.map (\x -> ( x, y )) (List.range 0 8))
                (List.range 0 8)

        cellRect ( x, y ) =
            let
                isFinder =
                    (x < 2 && y < 2) || (x > 6 && y < 2) || (x < 2 && y > 6)

                bitOn =
                    modBy 2 ((seedSum + x * 7 + y * 13 + x * y) // 3) == 0
            in
            if isFinder || bitOn then
                [ Svg.rect
                    [ SA.x (String.fromInt (x * 4 + 2))
                    , SA.y (String.fromInt (y * 4 + 2))
                    , SA.width "3.4"
                    , SA.height "3.4"
                    , SA.fill "#1b0509"
                    ]
                    []
                ]

            else
                []
    in
    Svg.svg
        [ SA.width "40"
        , SA.height "40"
        , SA.viewBox "0 0 40 40"
        , style "border" "1px solid var(--rule-strong)"
        , style "background" "#ffffff"
        , style "flex-shrink" "0"
        ]
        (List.concatMap cellRect coords)



-- 6. INTEGRATIONS


viewEcosystem : Snapshot -> Html Msg
viewEcosystem snap =
    div []
        [ div [ class "editorial-head" ]
            [ div []
                [ div [ class "editorial-kicker" ] [ text "Sister Ecosystem Bridge" ]
                , h1 [ class "editorial-title" ] [ text "FlowMation & Senviok" ]
                , p [ class "editorial-sub" ]
                    [ text "HMAC-SHA256 signed webhooks into FlowMation workflows and Stop-on-Paid dispatches via Senviok." ]
                ]
            , div [ class "head-controls" ]
                [ button [ class "btn btn-primary", onClick RequestFlowMationPack ]
                    [ text "Solution Pack (.json)" ]
                ]
            ]
        , div [ class "figure-strip cols-3" ]
            [ div [ class "figure-cell" ]
                [ div [ class "figure-kicker" ] [ text "FlowMation Hook" ]
                , div [ class "mono", style "margin-top" "6px", style "font-weight" "600", style "word-break" "break-all" ]
                    [ text snap.workspace.flowmationUrl ]
                , div [ class "figure-caption" ] [ text "Header: X-Ugwo-Signature" ]
                ]
            , div [ class "figure-cell" ]
                [ div [ class "figure-kicker" ] [ text "Senviok Sender" ]
                , div [ class "figure-num" ] [ text snap.workspace.senviokSender ]
                , div [ class "figure-caption" ] [ text "WhatsApp, Email, and DND SMS" ]
                ]
            , div [ class "figure-cell" ]
                [ div [ class "figure-kicker" ] [ text "Workspace Key" ]
                , div [ class "mono", style "margin-top" "6px", style "font-weight" "600" ]
                    [ text snap.workspace.apiKey ]
                , div [ class "figure-caption" ] [ text "Integer minor-unit contract" ]
                ]
            ]
        , div [ class "ledger-section" ]
            [ div [ class "section-bar" ]
                [ h2 [ class "section-heading" ] [ text "Cryptographic Outbox" ]
                , span [ class "section-note" ] [ text "Select Inspect to verify signature headers and JSON payloads." ]
                ]
            , div [ class "entry-list" ]
                (List.map
                    (\ev ->
                        div [ class "entry-row two-col" ]
                            [ div [ class "entry-primary" ]
                                [ div [ class "entry-serial" ] [ text (String.toUpper (humanChannel ev.target) ++ " · " ++ ev.createdAt) ]
                                , div [ class "entry-title mono", style "font-size" "13px" ] [ text ev.eventType ]
                                , div [ class "entry-sub mono" ] [ text ev.destination ]
                                ]
                            , div [ class "entry-tail" ]
                                [ if ev.status == "suppressed_stop_on_paid" then
                                    statusMark "wine" "Stop-on-Paid · 0 Cr"

                                  else if ev.creditsUsed > 0 then
                                    statusMark "settled" ("Delivered · " ++ String.fromInt ev.creditsUsed ++ " Cr")

                                  else
                                    statusMark "settled" "Signed"
                                , button [ class "btn btn-sm", onClick (OpenEventModal ev) ] [ text "Inspect" ]
                                ]
                            ]
                    )
                    snap.events
                )
            ]
        ]



-- MODALS


viewModal : ModalState -> Html Msg
viewModal modalState =
    case modalState of
        NoModal ->
            text ""

        NewSubModal f ->
            div [ class "modal-veil" ]
                [ div [ class "modal-sheet" ]
                    [ div [ class "modal-top" ]
                        [ h2 [ class "serif", style "margin" "0", style "font-size" "18px" ] [ text "Provision Subscriber" ]
                        , button [ class "btn btn-sm btn-quiet", onClick CloseModal ] [ text "Close" ]
                        ]
                    , Html.form [ onSubmit SubmitNewSub ]
                        [ div [ class "modal-content" ]
                            [ div [ class "form-grid" ]
                                [ div [ class "field" ]
                                    [ label [] [ text "Company" ]
                                    , input [ value f.company, onInput (\v -> UpdateSubForm (\x -> { x | company = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Contact" ]
                                    , input [ value f.contact, onInput (\v -> UpdateSubForm (\x -> { x | contact = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Phone" ]
                                    , input [ value f.phone, onInput (\v -> UpdateSubForm (\x -> { x | phone = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Country" ]
                                    , select [ onInput (\v -> UpdateSubForm (\x -> { x | country = v })) ]
                                        [ option [ value "NG" ] [ text "Nigeria (+234)" ]
                                        , option [ value "KE" ] [ text "Kenya (+254)" ]
                                        , option [ value "GH" ] [ text "Ghana (+233)" ]
                                        , option [ value "CI" ] [ text "Cote d'Ivoire (+225)" ]
                                        , option [ value "ZA" ] [ text "South Africa (+27)" ]
                                        ]
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Currency" ]
                                    , select [ onInput (\v -> UpdateSubForm (\x -> { x | currency = v })) ]
                                        [ option [ value "NGN" ] [ text "NGN (Naira)" ]
                                        , option [ value "KES" ] [ text "KES (Shilling)" ]
                                        , option [ value "GHS" ] [ text "GHS (Cedi)" ]
                                        , option [ value "XOF" ] [ text "XOF (CFA, 0-decimal)" ]
                                        , option [ value "ZAR" ] [ text "ZAR (Rand)" ]
                                        ]
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Tax ID (TIN / PIN)" ]
                                    , input [ value f.tin, onInput (\v -> UpdateSubForm (\x -> { x | tin = v })) ] []
                                    ]
                                ]
                            ]
                        , div [ class "modal-actions" ]
                            [ button [ type_ "button", class "btn", onClick CloseModal ] [ text "Cancel" ]
                            , button [ type_ "submit", class "btn btn-primary" ] [ text "Create Subscriber" ]
                            ]
                        ]
                    ]
                ]

        NewProjectModal f ->
            div [ class "modal-veil" ]
                [ div [ class "modal-sheet" ]
                    [ div [ class "modal-top" ]
                        [ h2 [ class "serif", style "margin" "0", style "font-size" "18px" ] [ text "New Milestone Voucher" ]
                        , button [ class "btn btn-sm btn-quiet", onClick CloseModal ] [ text "Close" ]
                        ]
                    , Html.form [ onSubmit SubmitNewProject ]
                        [ div [ class "modal-content" ]
                            [ div [ class "form-grid" ]
                                [ div [ class "field full" ]
                                    [ label [] [ text "Milestone Title" ]
                                    , input [ value f.title, onInput (\v -> UpdateProjectForm (\x -> { x | title = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Client Company" ]
                                    , input [ value f.company, onInput (\v -> UpdateProjectForm (\x -> { x | company = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Client Contact" ]
                                    , input [ value f.contact, onInput (\v -> UpdateProjectForm (\x -> { x | contact = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "WhatsApp Phone" ]
                                    , input [ value f.phone, onInput (\v -> UpdateProjectForm (\x -> { x | phone = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Currency" ]
                                    , select [ onInput (\v -> UpdateProjectForm (\x -> { x | currency = v })) ]
                                        [ option [ value "NGN" ] [ text "NGN (7.5% VAT)" ]
                                        , option [ value "KES" ] [ text "KES (16% VAT)" ]
                                        , option [ value "XOF" ] [ text "XOF (0-decimal)" ]
                                        ]
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Subtotal" ]
                                    , input [ value f.subtotalMajor, onInput (\v -> UpdateProjectForm (\x -> { x | subtotalMajor = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Withholding Tax" ]
                                    , select [ onInput (\v -> UpdateProjectForm (\x -> { x | whtBps = v })) ]
                                        [ option [ value "500" ] [ text "5% WHT" ]
                                        , option [ value "1000" ] [ text "10% WHT" ]
                                        , option [ value "0" ] [ text "No WHT" ]
                                        ]
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Revision Cap" ]
                                    , input [ value f.revCap, onInput (\v -> UpdateProjectForm (\x -> { x | revCap = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Deliverable Title" ]
                                    , input [ value f.deliverable, onInput (\v -> UpdateProjectForm (\x -> { x | deliverable = v })) ] []
                                    ]
                                ]
                            ]
                        , div [ class "modal-actions" ]
                            [ button [ type_ "button", class "btn", onClick CloseModal ] [ text "Cancel" ]
                            , button [ type_ "submit", class "btn btn-primary" ] [ text "Issue Voucher" ]
                            ]
                        ]
                    ]
                ]

        NewLeadModal f ->
            div [ class "modal-veil" ]
                [ div [ class "modal-sheet" ]
                    [ div [ class "modal-top" ]
                        [ h2 [ class "serif", style "margin" "0", style "font-size" "18px" ] [ text "Log WhatsApp Ad Lead" ]
                        , button [ class "btn btn-sm btn-quiet", onClick CloseModal ] [ text "Close" ]
                        ]
                    , Html.form [ onSubmit SubmitNewLead ]
                        [ div [ class "modal-content" ]
                            [ div [ class "form-grid" ]
                                [ div [ class "field" ]
                                    [ label [] [ text "Platform" ]
                                    , select [ onInput (\v -> UpdateLeadForm (\x -> { x | platform = v })) ]
                                        [ option [ value "meta_ctwa" ] [ text "Meta Click-to-WhatsApp" ]
                                        , option [ value "tiktok_messaging" ] [ text "TikTok Messaging Ads" ]
                                        ]
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Campaign" ]
                                    , input [ value f.campaign, onInput (\v -> UpdateLeadForm (\x -> { x | campaign = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Creative" ]
                                    , input [ value f.creative, onInput (\v -> UpdateLeadForm (\x -> { x | creative = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Buyer Name" ]
                                    , input [ value f.buyer, onInput (\v -> UpdateLeadForm (\x -> { x | buyer = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Phone" ]
                                    , input [ value f.phone, onInput (\v -> UpdateLeadForm (\x -> { x | phone = v })) ] []
                                    ]
                                , div [ class "field" ]
                                    [ label [] [ text "Order Value (NGN)" ]
                                    , input [ value f.amountMajor, onInput (\v -> UpdateLeadForm (\x -> { x | amountMajor = v })) ] []
                                    ]
                                , div [ class "field full" ]
                                    [ label [] [ text "First WhatsApp Message" ]
                                    , input [ value f.firstMsg, onInput (\v -> UpdateLeadForm (\x -> { x | firstMsg = v })) ] []
                                    ]
                                ]
                            ]
                        , div [ class "modal-actions" ]
                            [ button [ type_ "button", class "btn", onClick CloseModal ] [ text "Cancel" ]
                            , button [ type_ "submit", class "btn btn-primary" ] [ text "Record Lead" ]
                            ]
                        ]
                    ]
                ]

        ClientPortalModal proj ->
            div [ class "modal-veil" ]
                [ div [ class "modal-sheet" ]
                    [ div [ class "modal-top" ]
                        [ div []
                            [ div [ class "entry-serial" ] [ text ("CLIENT PORTAL · " ++ String.toUpper proj.clientCompany) ]
                            , h2 [ class "serif", style "margin" "0", style "font-size" "18px" ] [ text proj.title ]
                            ]
                        , button [ class "btn btn-sm btn-quiet", onClick CloseModal ] [ text "Close" ]
                        ]
                    , div [ class "modal-content" ]
                        [ div [ class "figure-strip cols-3", style "margin-bottom" "16px" ]
                            [ div [ class "figure-cell", style "padding" "12px 14px" ]
                                [ div [ class "figure-kicker" ] [ text "Balance Due" ]
                                , div [ class "figure-num", style "font-size" "17px" ] [ text proj.remainingFormatted ]
                                ]
                            , div [ class "figure-cell", style "padding" "12px 14px" ]
                                [ div [ class "figure-kicker" ] [ text "WHT Credit" ]
                                , div [ class "figure-num", style "font-size" "17px" ] [ text proj.whtFormatted ]
                                ]
                            , div [ class "figure-cell", style "padding" "12px 14px" ]
                                [ div [ class "figure-kicker" ] [ text "Revisions" ]
                                , div [ class "figure-num", style "font-size" "17px" ]
                                    [ text (String.fromInt proj.revisionsUsed ++ " / " ++ String.fromInt proj.revisionsIncluded) ]
                                ]
                            ]
                        , div [ class "ledger-section", style "margin-bottom" "0" ]
                            [ div [ class "entry-list" ]
                                (List.map
                                    (\d ->
                                        div [ class "entry-row two-col" ]
                                            [ div [ class "entry-primary" ]
                                                [ div [ class "entry-title" ] [ text d.title ]
                                                , div [ class "entry-sub" ]
                                                    [ if proj.vaultUnlocked then
                                                        span [ class "mono", style "color" "var(--ink-settled)" ] [ text d.downloadUrl ]

                                                      else
                                                        text (d.preview ++ " [Raw link withheld by server]")
                                                    ]
                                                ]
                                            , if proj.vaultUnlocked then
                                                statusMark "settled" "Unlocked"

                                              else
                                                statusMark "hold" "Locked"
                                            ]
                                    )
                                    proj.deliverables
                                )
                            ]
                        ]
                    , div [ class "modal-actions" ]
                        [ button [ class "btn", onClick CloseModal ] [ text "Close" ]
                        , if proj.remainingMinor > 0 then
                            button [ class "btn btn-primary", onClick (RunAction "/api/projects/settle" proj.id) ]
                                [ text ("Settle " ++ proj.remainingFormatted ++ " & Unlock") ]

                          else
                            text ""
                        ]
                    ]
                ]

        EventInspectModal ev ->
            div [ class "modal-veil" ]
                [ div [ class "modal-sheet" ]
                    [ div [ class "modal-top" ]
                        [ div []
                            [ div [ class "entry-serial" ] [ text (String.toUpper (humanChannel ev.target)) ]
                            , h2 [ class "mono", style "margin" "0", style "font-size" "14px" ] [ text ev.eventType ]
                            ]
                        , button [ class "btn btn-sm btn-quiet", onClick CloseModal ] [ text "Close" ]
                        ]
                    , div [ class "modal-content" ]
                        [ div [ class "field", style "margin-bottom" "12px" ]
                            [ label [] [ text "Destination" ]
                            , div [ class "mono" ] [ text ev.destination ]
                            ]
                        , div [ class "field", style "margin-bottom" "12px" ]
                            [ label [] [ text "Signature / Guard Header" ]
                            , div [ class "mono", style "word-break" "break-all" ] [ text ev.signatureHeader ]
                            ]
                        , div [ class "field" ]
                            [ label [] [ text "JSON Payload" ]
                            , div [ class "code-plate" ] [ text ev.payloadJson ]
                            ]
                        ]
                    , div [ class "modal-actions" ]
                        [ button [ class "btn", onClick CloseModal ] [ text "Done" ] ]
                    ]
                ]

        FlowMationPackModal packStr ->
            div [ class "modal-veil" ]
                [ div [ class "modal-sheet" ]
                    [ div [ class "modal-top" ]
                        [ h2 [ class "serif", style "margin" "0", style "font-size" "18px" ] [ text "FlowMation Solution Pack" ]
                        , button [ class "btn btn-sm btn-quiet", onClick CloseModal ] [ text "Close" ]
                        ]
                    , div [ class "modal-content" ]
                        [ p [ class "section-note", style "margin" "0 0 12px" ]
                            [ text "Import into FlowMation Studio to trigger post-settlement fulfillment and Senviok receipts." ]
                        , div [ class "code-plate", style "max-height" "320px" ] [ text packStr ]
                        ]
                    , div [ class "modal-actions" ]
                        [ button [ class "btn", onClick CloseModal ] [ text "Close" ]
                        , a [ class "btn btn-primary", href "/api/ecosystem/flowmation-pack.json", download "ugwo-flowmation-pack.json" ]
                            [ text "Download .json" ]
                        ]
                    ]
                ]
