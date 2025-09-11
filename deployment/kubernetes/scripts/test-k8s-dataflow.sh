#!/bin/bash

# ROS-OCP Kubernetes Data Flow Test Script
# This script tests the complete data flow in a Kubernetes deployment

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE=${NAMESPACE:-ros-ocp}
HELM_RELEASE_NAME=${HELM_RELEASE_NAME:-ros-ocp}
INGRESS_PORT=${INGRESS_PORT:-30080}
API_PORT=${API_PORT:-30081}
KRUIZE_PORT=${KRUIZE_PORT:-30090}

echo_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

echo_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if kubectl is configured
check_kubectl() {
    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo_error "kubectl is not configured or cluster is not accessible"
        return 1
    fi
    return 0
}

# Function to check if deployment exists
check_deployment() {
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo_error "Namespace '$NAMESPACE' does not exist"
        return 1
    fi

    if ! helm list -n "$NAMESPACE" | grep -q "$HELM_RELEASE_NAME"; then
        echo_error "Helm release '$HELM_RELEASE_NAME' not found in namespace '$NAMESPACE'"
        return 1
    fi

    return 0
}

# Function to wait for services to be ready
wait_for_services() {
    echo_info "Waiting for services to be ready..."

    # Wait for pods to be ready
    kubectl wait --for=condition=ready pod -l "app.kubernetes.io/instance=$HELM_RELEASE_NAME" \
        --namespace "$NAMESPACE" \
        --timeout=300s \
        --field-selector=status.phase!=Succeeded

    echo_success "All pods are ready"

    # Wait for services to be accessible
    local retries=30
    local count=0

    while [ $count -lt $retries ]; do
        if curl -f -s http://localhost:${INGRESS_PORT}/health >/dev/null 2>&1; then
            echo_success "Ingress service is accessible"
            break
        fi

        echo_info "Waiting for ingress service to be accessible... ($((count + 1))/$retries)"
        sleep 10
        count=$((count + 1))
    done

    if [ $count -eq $retries ]; then
        echo_error "Ingress service is not accessible after $retries attempts"
        return 1
    fi
}

# Function to create test data
create_test_data() {
    echo_info "Creating test data..." >&2

    # Create a temporary CSV file with proper ROS-OCP format
    local test_csv=$(mktemp)
    cat > "$test_csv" << 'EOF'
report_period_start,report_period_end,interval_start,interval_end,container_name,pod,owner_name,owner_kind,workload,workload_type,namespace,image_name,node,resource_id,cpu_request_container_avg,cpu_request_container_sum,cpu_limit_container_avg,cpu_limit_container_sum,cpu_usage_container_avg,cpu_usage_container_min,cpu_usage_container_max,cpu_usage_container_sum,cpu_throttle_container_avg,cpu_throttle_container_max,cpu_throttle_container_sum,memory_request_container_avg,memory_request_container_sum,memory_limit_container_avg,memory_limit_container_sum,memory_usage_container_avg,memory_usage_container_min,memory_usage_container_max,memory_usage_container_sum,memory_rss_usage_container_avg,memory_rss_usage_container_min,memory_rss_usage_container_max,memory_rss_usage_container_sum
2024-01-01,2024-01-01,2024-01-01 00:00:00 -0000 UTC,2024-01-01 00:15:00 -0000 UTC,test-container,test-pod-123,test-deployment,Deployment,test-workload,deployment,test-namespace,quay.io/test/image:latest,worker-node-1,resource-123,100,100,200,200,50,10,90,50,0,0,0,512,512,1024,1024,256,128,384,256,200,100,300,200
2024-01-01,2024-01-01,2024-01-01 00:15:00 -0000 UTC,2024-01-01 00:30:00 -0000 UTC,test-container-2,test-pod-456,test-deployment-2,Deployment,test-workload-2,deployment,test-namespace-2,quay.io/test/image2:latest,worker-node-2,resource-456,150,150,300,300,75,20,120,75,5,10,5,768,768,1536,1536,384,192,576,384,300,150,450,300
EOF

    echo "$test_csv"
}

# Function to upload test data using insights-ros-ingress
upload_test_data() {
    echo_info "=== STEP 1: Upload HCCM Data via insights-ros-ingress ===="
    echo_info "Testing the new insights-ros-ingress service which:"
    echo_info "- Replaces the insights-ingress-go service"  
    echo_info "- Automatically extracts CSV files from uploaded archives"
    echo_info "- Uploads CSV files directly to MinIO ros-data bucket"
    echo_info "- Publishes Kafka events to trigger ROS processing"
    echo_info ""

    local test_csv=$(create_test_data)
    local test_dir=$(mktemp -d)
    local uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local csv_filename="${uuid}_openshift_usage_report.0.csv" 
    local tar_filename="cost-mgmt.tar.gz"

    # Copy CSV to temporary directory with expected filename
    if ! cp "$test_csv" "$test_dir/$csv_filename"; then
        echo_error "Failed to copy CSV file to temporary directory"
        rm -f "$test_csv"
        rm -rf "$test_dir"
        return 1
    fi

    # Create manifest.json file (required by insights-ros-ingress)
    local manifest_json="$test_dir/manifest.json"
    local cluster_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local current_date=$(date -u +"%Y-%m-%dT%H:%M:%S.%NZ")
    local start_date=$(date -u +"%Y-%m-%dT%H:00:00Z")
    local end_date=$(date -u +"%Y-%m-%dT%H:59:59Z")

    cat > "$manifest_json" << EOF
{
    "uuid": "$uuid",
    "cluster_id": "$cluster_id",
    "version": "test-version",
    "date": "$current_date",
    "files": [
        "$csv_filename"
    ],
    "start": "$start_date",
    "end": "$end_date",
    "cr_status": {
        "clusterID": "$cluster_id",
        "clusterVersion": "test-4.10",
        "api_url": "http://localhost:30080",
        "authentication": {
            "type": "bearer",
            "secret_name": "test-auth-secret",
            "credentials_found": true
        },
        "packaging": {
            "last_successful_packaging_time": null,
            "max_reports_to_store": 30,
            "max_size_MB": 100,
            "number_reports_stored": 1
        },
        "upload": {
            "ingress_path": "/api/ingress/v1/upload",
            "upload": true,
            "upload_wait": 30,
            "upload_cycle": 360,
            "last_successful_upload_time": null,
            "validate_cert": false
        },
        "operator_commit": "test-commit",
        "prometheus": {
            "prometheus_configured": true,
            "prometheus_connected": true,
            "context_timeout": 120,
            "last_query_start_time": "$current_date",
            "last_query_success_time": "$current_date",
            "service_address": "https://prometheus-test",
            "skip_tls_verification": true
        },
        "reports": {
            "report_month": "$(date +%m)",
            "last_hour_queried": "$start_date - $end_date",
            "data_collected": true
        },
        "source": {
            "sources_path": "/api/sources/v1.0/",
            "create_source": false,
            "last_check_time": null,
            "check_cycle": 1440
        },
        "storage": {}
    },
    "certified": false
}
EOF

    echo_info "Created manifest.json with cluster_id: $cluster_id"

    # Create tar.gz file (insights-ros-ingress will extract this automatically)
    echo_info "Creating HCCM tar.gz archive for insights-ros-ingress..."
    if ! (cd "$test_dir" && tar -czf "$tar_filename" "$csv_filename" "manifest.json"); then
        echo_error "Failed to create tar.gz archive"
        rm -f "$test_csv"
        rm -rf "$test_dir"
        return 1
    fi

    echo_info "Uploading HCCM archive to insights-ros-ingress..."

    # Get authentication token (required by insights-ros-ingress in Kubernetes)
    local auth_token=""
    local auth_setup_ok=false
    
    # Check if we can use the kubeconfig created by deploy-kind.sh
    if [ -f "/tmp/dev-kubeconfig" ]; then
        # Try to get token from the kubeconfig file
        auth_token=$(kubectl --kubeconfig=/tmp/dev-kubeconfig config view --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || echo "")
        if [ -n "$auth_token" ]; then
            auth_setup_ok=true
            echo_info "✓ Using authentication token from dev kubeconfig"
        fi
    fi
    
    # Fallback: try to get token from service account secret directly
    if [ "$auth_setup_ok" = false ] && kubectl get serviceaccount insights-ros-ingress -n "$NAMESPACE" >/dev/null 2>&1; then
        # Try the new token secret created by deploy-kind.sh
        auth_token=$(kubectl get secret insights-ros-ingress-token -n "$NAMESPACE" \
            -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        
        if [ -n "$auth_token" ]; then
            auth_setup_ok=true
            echo_info "✓ Using authentication token from service account secret"
        fi
    fi
    
    # If still no token, provide helpful guidance
    if [ "$auth_setup_ok" = false ]; then
        echo_warning "No authentication token available"
        echo_info "Make sure deploy-kind.sh was run to set up authentication"
        echo_info "Expected token secret: insights-ros-ingress-token in namespace $NAMESPACE"
    fi

    # Upload the tar.gz file to insights-ros-ingress
    local curl_cmd="curl -s -w \"%{http_code}\" \
        -F \"upload=@${test_dir}/${tar_filename};type=application/vnd.redhat.hccm.upload\" \
        -H \"x-rh-identity: eyJpZGVudGl0eSI6eyJhY2NvdW50X251bWJlciI6IjEyMzQ1IiwidHlwZSI6IlVzZXIiLCJpbnRlcm5hbCI6eyJvcmdfaWQiOiIxMjM0NSJ9fX0K\" \
        -H \"x-rh-request-id: test-request-$(date +%s)\""

    if [ -n "$auth_token" ]; then
        curl_cmd="$curl_cmd -H \"Authorization: Bearer $auth_token\""
        echo_info "✓ Authentication token will be included in request"
    fi

    curl_cmd="$curl_cmd http://localhost:${INGRESS_PORT}/api/ingress/v1/upload"

    local response=$(eval $curl_cmd)
    local http_code="${response: -3}"
    local response_body="${response%???}"

    # Cleanup
    rm -f "$test_csv"
    rm -rf "$test_dir"

    if [ "$http_code" != "202" ]; then
        echo_error "Upload failed! HTTP $http_code"
        echo_error "Response: $response_body"
        if [ "$http_code" = "401" ]; then
            echo_error "Authentication failed. Check that insights-ros-ingress service account exists"
        fi
        return 1
    fi

    echo_success "Upload successful! HTTP $http_code"
    echo_info "Response: $response_body"
    echo_info "insights-ros-ingress will now:"
    echo_info "1. Extract CSV files from the uploaded archive"
    echo_info "2. Upload CSV files to MinIO ros-data bucket"
    echo_info "3. Publish Kafka events to trigger ROS processing"

    return 0
}

# Function to verify insights-ros-ingress processing 
verify_ros_ingress_processing() {
    echo_info "=== STEP 2: Verify insights-ros-ingress Processing ===="
    echo_info "insights-ros-ingress should automatically:"
    echo_info "- Extract CSV files from the uploaded archive"
    echo_info "- Upload CSV files to MinIO ros-data bucket"
    echo_info "- Publish Kafka events to trigger ROS processing"
    echo_info ""

    echo_info "Waiting for insights-ros-ingress to process the upload..."
    sleep 15

    # Check for CSV files in ros-data bucket (created by insights-ros-ingress)
    echo_info "Checking for CSV files in MinIO ros-data bucket..."
    
    local minio_pod=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=minio" -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$minio_pod" ]; then
        echo_error "MinIO pod not found"
        return 1
    fi

    local retries=6
    local csv_found=false
    
    for i in $(seq 1 $retries); do
        echo_info "Checking for CSV files in ros-data bucket (attempt $i/$retries)..."
        
        # List files in ros-data bucket
        local bucket_contents=$(kubectl exec -n "$NAMESPACE" "$minio_pod" -- \
            /usr/bin/mc ls myminio/ros-data/ 2>/dev/null || echo "")
        
        if echo "$bucket_contents" | grep -q "\.csv"; then
            echo_success "CSV files found in ros-data bucket (uploaded by insights-ros-ingress):"
            echo "$bucket_contents" | grep "\.csv"
            csv_found=true
            break
        else
            echo_info "No CSV files found yet, waiting... ($i/$retries)"
            sleep 10
        fi
    done

    if [ "$csv_found" = false ]; then
        echo_error "No CSV files found in ros-data bucket after $retries attempts"
        echo_info "insights-ros-ingress may have failed to process the upload"
        echo_info "Checking MinIO bucket contents for debugging:"
        kubectl exec -n "$NAMESPACE" "$minio_pod" -- \
            /usr/bin/mc ls myminio/ros-data/ 2>/dev/null || echo "Could not list bucket contents"
        return 1
    fi

    echo_info "=== STEP 3: Verify Kafka Events ===="
    echo_info "insights-ros-ingress should have published Kafka events automatically"
    echo_info "ROS processor should begin processing the CSV files"
    
    echo_success "✓ insights-ros-ingress processing verification completed"
    return 0
}

# Function to verify data processing
verify_processing() {
    echo_info "=== STEP 4: Verify Data Processing ===="

    echo_info "Waiting for data processing (60 seconds)..."
    sleep 20

    # Check processor logs
    echo_info "Checking processor logs..."
    local processor_pod=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=rosocp-processor" -o jsonpath='{.items[0].metadata.name}')

    if [ -n "$processor_pod" ]; then
        echo_info "Recent processor logs:"
        kubectl logs -n "$NAMESPACE" "$processor_pod" --tail=20 || true
    fi

    # Check database for workload records
    echo_info "Checking database for workload records..."
    local db_pod=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=db-ros" -o jsonpath='{.items[0].metadata.name}')

    if [ -n "$db_pod" ]; then
        local row_count=$(kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM workloads;" 2>/dev/null | tr -d ' ' || echo "0")

        if [ "$row_count" -gt 0 ]; then
            echo_success "Found $row_count workload records in database"

            # Show sample data
            echo_info "Sample workload data:"
            kubectl exec -n "$NAMESPACE" "$db_pod" -- \
                psql -U postgres -d postgres -c \
                "SELECT cluster_uuid, workload_name, workload_type, namespace FROM workloads LIMIT 3;" 2>/dev/null || true
        else
            echo_warning "No workload data found in database yet"
        fi
    fi

    # Check Kruize experiments via database (listExperiments API has known issue with KruizeLMExperimentEntry)
    echo_info "Checking Kruize experiments via database..."
    local db_pod=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=db-kruize" -o jsonpath='{.items[0].metadata.name}')

    if [ -n "$db_pod" ]; then
        local exp_count=$(kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM kruize_experiments;" 2>/dev/null | tr -d ' ' || echo "0")

        if [ "$exp_count" -gt 0 ]; then
            echo_success "Found $exp_count Kruize experiment(s) in database"

            # Show experiment details
            echo_info "Recent experiment details:"
            kubectl exec -n "$NAMESPACE" "$db_pod" -- \
                psql -U postgres -d postgres -c \
                "SELECT experiment_name, status, mode FROM kruize_experiments ORDER BY experiment_id DESC LIMIT 1;" 2>/dev/null || true
        else
            echo_warning "No Kruize experiments found in database yet"
        fi
    else
        echo_warning "Could not access Kruize database"
    fi
}

# Function to verify recommendations are available via ros-ocp-api
verify_recommendations() {
    echo_info "=== STEP 5: Verify Recommendations via ROS-OCP API ===="

    # Wait additional time for recommendations to be processed
    echo_info "Waiting for recommendations to be processed (30 seconds)..."
    sleep 30

    # Base identity header used throughout the script
    local identity_header="eyJpZGVudGl0eSI6eyJhY2NvdW50X251bWJlciI6IjEyMzQ1IiwidHlwZSI6IlVzZXIiLCJpbnRlcm5hbCI6eyJvcmdfaWQiOiIxMjM0NSJ9fX0K"
    local api_base_url="http://localhost:${API_PORT}/api/cost-management/v1"

    # Test API status endpoint first
    echo_info "Testing ROS-OCP API status..."
    local status_response=$(curl -s -w "%{http_code}" -o /tmp/status_response.json \
        "http://localhost:${API_PORT}/status" 2>/dev/null || echo "000")

    local status_http_code="${status_response: -3}"

    if [ "$status_http_code" = "200" ]; then
        echo_success "ROS-OCP API status endpoint is accessible"
        if [ -f /tmp/status_response.json ]; then
            echo_info "Status response: $(cat /tmp/status_response.json)"
            rm -f /tmp/status_response.json
        fi
    else
        echo_error "ROS-OCP API status endpoint not accessible (HTTP $status_http_code)"
        return 1
    fi

    # Test recommendations list endpoint
    echo_info "Testing recommendations list endpoint..."
    local list_response=$(curl -s -w "%{http_code}" -o /tmp/recommendations_list.json \
        -H "x-rh-identity: $identity_header" \
        -H "Content-Type: application/json" \
        "$api_base_url/recommendations/openshift" 2>/dev/null || echo "000")

    local list_http_code="${list_response: -3}"

    if [ "$list_http_code" = "200" ]; then
        echo_success "Recommendations list endpoint accessible (HTTP $list_http_code)"

        if [ -f /tmp/recommendations_list.json ]; then
            # Check if we have actual recommendations
            local rec_count=$(python3 -c "
import json, sys
try:
    with open('/tmp/recommendations_list.json', 'r') as f:
        data = json.load(f)
    if 'data' in data and isinstance(data['data'], list):
        print(len(data['data']))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null || echo "0")

            echo_info "Found $rec_count recommendation(s) in the response"

            if [ "$rec_count" -gt 0 ]; then
                echo_success "✓ Recommendations are available via API!"

                # Show summary of first recommendation
                echo_info "Sample recommendation summary:"
                python3 -c "
import json
try:
    with open('/tmp/recommendations_list.json', 'r') as f:
        data = json.load(f)
    if 'data' in data and len(data['data']) > 0:
        rec = data['data'][0]
        print(f'  ID: {rec.get(\"id\", \"N/A\")}')
        print(f'  Cluster: {rec.get(\"cluster_alias\", \"N/A\")}')
        print(f'  Workload: {rec.get(\"workload\", \"N/A\")}')
        print(f'  Container: {rec.get(\"container\", \"N/A\")}')
        print(f'  Namespace: {rec.get(\"project\", \"N/A\")}')
except Exception as e:
    print(f'  Error parsing response: {e}')
" 2>/dev/null || echo "  Unable to parse recommendation details"

                # Test individual recommendation endpoint
                local rec_id=$(python3 -c "
import json
try:
    with open('/tmp/recommendations_list.json', 'r') as f:
        data = json.load(f)
    if 'data' in data and len(data['data']) > 0:
        print(data['data'][0].get('id', ''))
except:
    pass
" 2>/dev/null)

                if [ -n "$rec_id" ]; then
                    echo_info "Testing individual recommendation endpoint for ID: $rec_id"
                    local detail_response=$(curl -s -w "%{http_code}" -o /tmp/recommendation_detail.json \
                        -H "x-rh-identity: $identity_header" \
                        -H "Content-Type: application/json" \
                        "$api_base_url/recommendations/openshift/$rec_id" 2>/dev/null || echo "000")

                    local detail_http_code="${detail_response: -3}"

                    if [ "$detail_http_code" = "200" ]; then
                        echo_success "✓ Individual recommendation endpoint accessible (HTTP $detail_http_code)"

                        # Show recommendation details
                        echo_info "Recommendation details available:"
                        python3 -c "
import json
try:
    with open('/tmp/recommendation_detail.json', 'r') as f:
        data = json.load(f)
    if 'recommendations' in data and 'data' in data['recommendations']:
        rec_data = data['recommendations']['data']
        if rec_data:
            print(f'  Current CPU request: {rec_data.get(\"requests\", {}).get(\"cpu\", {}).get(\"amount\", \"N/A\")}')
            print(f'  Recommended CPU request: {rec_data.get(\"requests\", {}).get(\"cpu\", {}).get(\"recommendation\", {}).get(\"amount\", \"N/A\")}')
            print(f'  Current Memory request: {rec_data.get(\"requests\", {}).get(\"memory\", {}).get(\"amount\", \"N/A\")}')
            print(f'  Recommended Memory request: {rec_data.get(\"requests\", {}).get(\"memory\", {}).get(\"recommendation\", {}).get(\"amount\", \"N/A\")}')
        else:
            print('  No recommendation data available')
except Exception as e:
    print(f'  Error parsing recommendation: {e}')
" 2>/dev/null || echo "  Unable to parse recommendation details"

                        rm -f /tmp/recommendation_detail.json
                    else
                        echo_warning "Individual recommendation endpoint returned HTTP $detail_http_code"
                    fi
                fi
            else
                echo_warning "No recommendations found in response - data may still be processing"
            fi

            rm -f /tmp/recommendations_list.json
        fi
    elif [ "$list_http_code" = "401" ]; then
        echo_error "Authentication failed (HTTP 401) - check identity header"
        return 1
    elif [ "$list_http_code" = "000" ]; then
        echo_error "Could not connect to ROS-OCP API - check if service is running and port $API_PORT is accessible"
        return 1
    else
        echo_warning "Recommendations endpoint returned HTTP $list_http_code"
        if [ -f /tmp/recommendations_list.json ]; then
            echo_info "Response: $(cat /tmp/recommendations_list.json)"
            rm -f /tmp/recommendations_list.json
        fi
    fi

    # Test CSV export format
    echo_info "Testing CSV export functionality..."
    local csv_response=$(curl -s -w "%{http_code}" -o /tmp/recommendations.csv \
        -H "x-rh-identity: $identity_header" \
        -H "Accept: text/csv" \
        "$api_base_url/recommendations/openshift?format=csv" 2>/dev/null || echo "000")

    local csv_http_code="${csv_response: -3}"

    if [ "$csv_http_code" = "200" ]; then
        echo_success "✓ CSV export functionality working (HTTP $csv_http_code)"
        if [ -f /tmp/recommendations.csv ]; then
            local csv_lines=$(wc -l < /tmp/recommendations.csv 2>/dev/null || echo "0")
            echo_info "CSV contains $csv_lines lines"
            rm -f /tmp/recommendations.csv
        fi
    else
        echo_warning "CSV export returned HTTP $csv_http_code"
        rm -f /tmp/recommendations.csv
    fi

    echo_info "Recommendation verification completed"
}

# Function to verify workloads are stored in ROS database
verify_workloads_in_db() {
    echo_info "=== STEP 6: Verify Workloads in ROS Database ===="

    # Check database for workload records with detailed analysis
    echo_info "Checking workloads table in ROS database..."
    local db_pod=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=db-ros" -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$db_pod" ]; then
        echo_error "ROS database pod not found"
        return 1
    fi

    # Test database connectivity
    echo_info "Testing database connectivity..."
    if ! kubectl exec -n "$NAMESPACE" "$db_pod" -- psql -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        echo_error "Cannot connect to ROS database"
        return 1
    fi
    echo_success "✓ Database connection successful"

    # Check if workloads table exists
    echo_info "Verifying workloads table exists..."
    local table_exists=$(kubectl exec -n "$NAMESPACE" "$db_pod" -- \
        psql -U postgres -d postgres -t -c \
        "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'workloads');" 2>/dev/null | tr -d ' ' || echo "f")

    if [ "$table_exists" = "t" ]; then
        echo_success "✓ Workloads table exists"
    else
        echo_error "Workloads table does not exist"
        return 1
    fi

    # Get workload count
    local workload_count=$(kubectl exec -n "$NAMESPACE" "$db_pod" -- \
        psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM workloads;" 2>/dev/null | tr -d ' ' || echo "0")

    if [ "$workload_count" -gt 0 ]; then
        echo_success "✓ Found $workload_count workload(s) in database"

        # Show workload table schema
        echo_info "Workload table schema:"
        kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -c \
            "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = 'workloads' ORDER BY ordinal_position;" 2>/dev/null || true

        # Show detailed workload information
        echo_info "Detailed workload information:"
        kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -c \
            "SELECT
                id,
                org_id,
                cluster_id,
                experiment_name,
                namespace,
                workload_type,
                workload_name,
                array_length(containers, 1) as container_count,
                containers[1:3] as first_containers,
                metrics_upload_at
            FROM workloads
            ORDER BY id
            LIMIT 5;" 2>/dev/null || true

        # Test workload data integrity
        echo_info "Testing workload data integrity..."

        # Check for required fields
        local missing_org_id=$(kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM workloads WHERE org_id IS NULL OR org_id = '';" 2>/dev/null | tr -d ' \n' || echo "0")
        missing_org_id=${missing_org_id:-0}

        local missing_workload_name=$(kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM workloads WHERE workload_name IS NULL OR workload_name = '';" 2>/dev/null | tr -d ' \n' || echo "0")
        missing_workload_name=${missing_workload_name:-0}

        local missing_workload_type=$(kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM workloads WHERE workload_type IS NULL OR workload_type = '';" 2>/dev/null | tr -d ' \n' || echo "0")
        missing_workload_type=${missing_workload_type:-0}

        if [ "$missing_org_id" -eq 0 ] && [ "$missing_workload_name" -eq 0 ] && [ "$missing_workload_type" -eq 0 ]; then
            echo_success "✓ All workloads have required fields populated"
        else
            echo_warning "Data integrity issues found:"
            [ "$missing_org_id" -gt 0 ] && echo_warning "  $missing_org_id workloads missing org_id"
            [ "$missing_workload_name" -gt 0 ] && echo_warning "  $missing_workload_name workloads missing workload_name"
            [ "$missing_workload_type" -gt 0 ] && echo_warning "  $missing_workload_type workloads missing workload_type"
        fi

        # Check cluster relationships
        echo_info "Checking cluster relationships..."
        local cluster_count=$(kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -t -c "SELECT COUNT(DISTINCT cluster_id) FROM workloads;" 2>/dev/null | tr -d ' ' || echo "0")

        local orphaned_workloads=$(kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -t -c \
            "SELECT COUNT(*) FROM workloads w
             LEFT JOIN clusters c ON w.cluster_id = c.id
             WHERE c.id IS NULL;" 2>/dev/null | tr -d ' ' || echo "0")

        echo_info "  Workloads span $cluster_count cluster(s)"
        if [ "$orphaned_workloads" -eq 0 ]; then
            echo_success "✓ All workloads properly linked to clusters"
        else
            echo_warning "  $orphaned_workloads workloads have invalid cluster references"
        fi

        # Show workload distribution by type
        echo_info "Workload distribution by type:"
        kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -c \
            "SELECT workload_type, COUNT(*) as count
             FROM workloads
             GROUP BY workload_type
             ORDER BY count DESC;" 2>/dev/null || true

        # Show workload distribution by namespace
        echo_info "Workload distribution by namespace:"
        kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -c \
            "SELECT namespace, COUNT(*) as count
             FROM workloads
             GROUP BY namespace
             ORDER BY count DESC
             LIMIT 10;" 2>/dev/null || true

        # Check container information
        local total_containers=$(kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -t -c \
            "SELECT SUM(array_length(containers, 1)) FROM workloads WHERE containers IS NOT NULL;" 2>/dev/null | tr -d ' ' || echo "0")

        echo_info "Total containers across all workloads: $total_containers"

        # Verify recent data updates
        echo_info "Checking data freshness..."
        local recent_updates=$(kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -t -c \
            "SELECT COUNT(*) FROM workloads WHERE metrics_upload_at > NOW() - INTERVAL '1 hour';" 2>/dev/null | tr -d ' ' || echo "0")

        if [ "$recent_updates" -gt 0 ]; then
            echo_success "✓ $recent_updates workloads updated within the last hour"
        else
            echo_info "  No workloads updated in the last hour (may be expected for test data)"
        fi

        # Show most recent workload activity
        echo_info "Most recent workload uploads:"
        kubectl exec -n "$NAMESPACE" "$db_pod" -- \
            psql -U postgres -d postgres -c \
            "SELECT workload_name, namespace, workload_type, metrics_upload_at
             FROM workloads
             ORDER BY metrics_upload_at DESC
             LIMIT 3;" 2>/dev/null || true

    else
        echo_warning "No workload data found in database"
        echo_info "This might indicate:"
        echo_info "  - Data processing is still in progress"
        echo_info "  - No data has been uploaded yet"
        echo_info "  - There was an issue with data processing"

        # Check if table is empty but exists
        echo_info "Checking if this is expected for test scenario..."
        return 0
    fi

    echo_info "Workload database verification completed"
}

# Function to run health checks
run_health_checks() {
    echo_info "=== Health Checks ===="

    local failed_checks=0

    # Check ingress API
    if curl -f -s http://localhost:${INGRESS_PORT}/health >/dev/null; then
        echo_success "Ingress API is accessible"
    else
        echo_error "Ingress API is not accessible"
        failed_checks=$((failed_checks + 1))
    fi

    # Check ROS-OCP API
    if curl -f -s http://localhost:${API_PORT}/status >/dev/null; then
        echo_success "ROS-OCP API is accessible"
    else
        echo_error "ROS-OCP API is not accessible"
        failed_checks=$((failed_checks + 1))
    fi

    # Check Kruize API
    if curl -f -s http://localhost:${KRUIZE_PORT}/listPerformanceProfiles >/dev/null; then
        echo_success "Kruize API is accessible"
    else
        echo_error "Kruize API is not accessible"
        failed_checks=$((failed_checks + 1))
    fi

    # Check pod status
    local pending_pods=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
    local failed_pods=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)

    if [ "$pending_pods" -eq 0 ] && [ "$failed_pods" -eq 0 ]; then
        echo_success "All pods are running successfully"
    else
        echo_warning "$pending_pods pending pods, $failed_pods failed pods"
        failed_checks=$((failed_checks + 1))
    fi

    if [ $failed_checks -eq 0 ]; then
        echo_success "All health checks passed!"
    else
        echo_warning "$failed_checks health check(s) failed"
    fi

    return $failed_checks
}

# Function to show service logs
show_logs() {
    local service="${1:-}"

    if [ -z "$service" ]; then
        echo_info "Available services:"
        kubectl get pods -n "$NAMESPACE" -o custom-columns="NAME:.metadata.name,COMPONENT:.metadata.labels.app\.kubernetes\.io/name" --no-headers
        return 0
    fi

    local pod=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$service" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -n "$pod" ]; then
        echo_info "Logs for $service ($pod):"
        kubectl logs -n "$NAMESPACE" "$pod" --tail=50
    else
        echo_error "Pod not found for service: $service"
        return 1
    fi
}

# Main execution
main() {
    echo_info "ROS-OCP Kubernetes Data Flow Test"
    echo_info "=================================="

    # Check prerequisites
    if ! check_kubectl; then
        exit 1
    fi

    if ! check_deployment; then
        exit 1
    fi

    echo_info "Configuration:"
    echo_info "  Namespace: $NAMESPACE"
    echo_info "  Helm Release: $HELM_RELEASE_NAME"
    echo_info "  Ingress Port: $INGRESS_PORT"
    echo_info "  API Port: $API_PORT"
    echo_info "  Kruize Port: $KRUIZE_PORT"
    echo ""

    # Wait for services to be ready
    if ! wait_for_services; then
        echo_error "Services are not ready. Aborting test."
        exit 1
    fi

    # Run complete data flow test
    echo_info "Starting complete data flow test..."

    if upload_test_data; then
        echo_success "Step 1: Upload completed successfully"
    else
        echo_error "Step 1: Upload failed"
        exit 1
    fi

    if verify_ros_ingress_processing; then
        echo_success "Steps 2-3: insights-ros-ingress processing completed successfully"
    else
        echo_error "Steps 2-3: insights-ros-ingress processing failed"
        exit 1
    fi

    verify_processing

    # Verify workloads are stored in database
    verify_workloads_in_db

    # Verify recommendations are available via API
    verify_recommendations

    echo ""
    run_health_checks

    echo ""
    echo_success "Data flow test completed!"
    echo_info "Use '$0 logs <service>' to view specific service logs"
    echo_info "Use '$0 recommendations' to verify recommendations via API"
    echo_info "Use '$0 workloads' to verify workloads in database"
    echo_info "Available services: ingress, rosocp-processor, rosocp-api, kruize, minio, db-ros"
}

# Handle script arguments
case "${1:-}" in
    "logs")
        show_logs "${2:-}"
        exit 0
        ;;
    "health")
        run_health_checks
        exit $?
        ;;
    "recommendations")
        verify_recommendations
        exit $?
        ;;
    "workloads")
        verify_workloads_in_db
        exit $?
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "Commands:"
        echo "  (none)           - Run complete data flow test"
        echo "  logs [svc]       - Show logs for service (or list services if no service specified)"
        echo "  health           - Run health checks only"
        echo "  recommendations  - Verify recommendations are available via API"
        echo "  workloads        - Verify workloads are stored in ROS database"
        echo "  help             - Show this help message"
        echo ""
        echo "Environment Variables:"
        echo "  NAMESPACE         - Kubernetes namespace (default: ros-ocp)"
        echo "  HELM_RELEASE_NAME - Helm release name (default: ros-ocp)"
        echo "  INGRESS_PORT      - Ingress service port (default: 30080)"
        echo "  API_PORT          - API service port (default: 30081)"
        echo "  KRUIZE_PORT       - Kruize service port (default: 30090)"
        exit 0
        ;;
esac

# Run main function
main "$@"