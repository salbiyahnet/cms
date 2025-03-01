#!/bin/bash
# 任何命令执行失败就直接退出
set -e

# 定义字体颜色样式
YELLOW='\033[33m'
GREEN='\033[32m'
RESET='\033[0m'
# 定义变量action，version，env_path
# 执行的操作类型install或者upgrade
action=""
# 安装或升级的CMS版本
version=""
# docker compose.yml的环境变量文件目录
env_path=".env"
# docker compose命令格式
docker_compose_command="docker compose"

# 解析外部传入的参数
while [[ "$#" -gt 0 ]]; do
    case $1 in
    --version=*)
        version="${1#*=}"
        ;;
    --version)
        shift
        version="$1"
        ;;
    install | upgrade)
        action="$1"
        ;;
    *)
        echo "Illegal parameter: $1"
        exit 1
        ;;
    esac
    shift
done
# version不能为空
if [[ ! -n "$version" ]]; then
    echo "CMS version can not be empty"
    exit 1
fi

if [[ ! -n "$action" ]]; then
    echo "install action can not be empty"
    exit 1
fi

######################################################################################################################################################
# 通用方法
# 修改键值对文件，key存在则覆盖value，key不存在则在文件尾部添加key=value
set_property() {
    local key=$1
    local value=$2
    local filepath=$3
    if grep -q "$key" $filepath; then
        # 在 sed 命令中，使用 | 作为分隔符可以避免斜杠 / 引起的问题
        sed -i "s|^$key=.*|$key=$value|" $filepath
    else
        echo "" >>$filepath
        echo "$key=$value" >>$filepath
    fi
}
# 检查端口是否被占用
check_port() {
    local port=$1
    if lsof -i :$port >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}
# 随机生成指定长度的字符串
generate_random_string() {
    local length=$1
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c $length
}
# 判断数组中是否包含指定元素
contains_element() {
    local ele
    for ele in "${@:2}"; do
        [[ "$ele" == "$1" ]] && return 0
    done
    return 1
}
######################################################################################################################################################
if [[ "$action" = "install" ]]; then
    echo ""
    echo "============================== Please select the service port =============================="
    echo ""
    # 1.用户确认端口占用情况
    # 服务默认端口
    mysql_port="3306"
    redis_port="6379"
    mqtt_port="1883"
    cms_acs_port="9909"
    cms_stun_port="3478"
    cms_boot_port="9999"
    nginx_port="80"
    # 数据卷默认存储目录
    data_volume=./

    # 存储serviceName，Value，Key
    port_array=(
        "mysql" "$mysql_port" "MYSQL_PORT"
        "redis" "$redis_port" "REDIS_PORT"
        "emqx" "$mqtt_port" "EMQX_PORT"
        "acs" "$cms_acs_port" "CMS_ACS_PORT"
        "stun" "$cms_stun_port" "CMS_STUN_PORT"
        "cms" "$cms_boot_port" "CMS_BOOT_PORT"
        "nginx" "$nginx_port" "NGINX_PORT"
    )
    # 遍历服务并修改端口
    for ((i = 0; i < ${#port_array[@]}; i += 3)); do
        service_name=${port_array[$i]}
        service_port=${port_array[$i + 1]}
        service_key=${port_array[$i + 2]}
        printf "$service_name service will use ${GREEN}$service_port${RESET} port, Do you need to modify it? [y/${GREEN}n${RESET}] "
        read -p "" answer
        # read -p "$service_name service will use $service_port port, Do you need to modify it? [y/n]" answer
        if [[ $answer =~ ^[Yy]$ ]]; then
            while true; do
                read -p "Please enter a new port: " new_port
                if [[ $new_port =~ ^[0-9]+$ ]]; then
                    if check_port $new_port; then
                        echo "The new port $new_port is already occupied, please choose another port."
                    else
                        echo "$service_name service new port is $new_port."
                        # service_port重新赋值
                        service_port=$new_port
                        break
                    fi
                else
                    echo "Invalid port, please enter a valid number."
                fi
            done
        fi
        set_property $service_key $service_port $env_path
    done

    echo ""
    echo "============================== Please select the data volume =============================="
    echo ""
    # 2.用户确定卷的挂载目录
    printf "CMS data will be stored in current directory. Do you need to modify it? [y/${GREEN}n${RESET}] "
    read -p "" answer
    # read -p "CMS data will be stored in current directory. Do you need to modify it? [y/n]" answer
    if [[ $answer =~ ^[Yy]$ ]]; then
        while true; do
            read -p "CMS data will be stored in directory: " new_data_volume
            if [[ -d $new_data_volume ]]; then
                data_volume=$new_data_volume
                echo "CMS data will be stored in $data_volume."
                break
            else
                echo "The $new_data_volume directory does not exist."
            fi
        done
    fi
    set_property VOLUME_PATH $data_volume $env_path
    if [[ ! -d "$data_volume/data/emqx" ]]; then
        mkdir -p "$data_volume/data/emqx"
    fi
    if [[ ! -d "$data_volume/log/emqx" ]]; then
        mkdir -p "$data_volume/log/emqx"
    fi
    chmod -R 777 "$data_volume/data/emqx" "$data_volume/log/emqx"
    # 3.随机生成MySQL的root密码
    echo ""
    # echo "============================== init MySQL service =============================="
    # echo ""
    # 检查是否已经初始化过MySQL的root密码，没有则写入.env文件
    if ! grep -q "MYSQL_ROOT_PASSWORD" $env_path; then
        # 随机生成16位长度的字符串作为MySQL的root密码
        mysql_root_password=$(generate_random_string 16)
        # 在文件尾添加一个换行
        echo "" >>$env_path
        # MySQL密码写入.evn文件
        echo "MYSQL_ROOT_PASSWORD=$mysql_root_password" >>$env_path
    fi
    # 启动MySQL服务进行初始化
    echo "Waiting for MySQL to start..."
    # 开始初始化MySQL
    $docker_compose_command down
    $docker_compose_command up -d mysql
    # 循环等待MySQL服务启动成功
    while
        ! docker exec -it cms-mysql sh -c 'mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" ccssx_boot -BN -e "select 1"' &>/dev/null
    do
        echo "Waiting for MySQL to start..."
        sleep 3
    done
    echo "MySQL started successfully!!!"

    # 4.初始化企业和用户，用户使用内置默认的账号密码
    echo ""
    echo "============================== Please init your tenant  =============================="
    echo ""
    # 企业类型，单租户或多租户，默认单租户
    tenant_type="isp"
    printf "Please select your tenant type, multi / ${GREEN}isp${RESET}: "
    read -p "" answer
    if [[ -n "$answer" ]]; then
        if [[ "$answer" != "isp" && "$answer" != "multi" ]]; then
            echo "Illegal input!!!"
            exit 1
        else
            tenant_type=$answer
        fi
    fi
    # 企业host，用于显示通道地址等
    tenant_host=""
    printf "Please select your tenant host: "
    read -p "" answer
    if [[ ! -n "$answer" ]]; then
        echo "tenant host cannot be empty!!!"
        exit 1
    else
        tenant_host=$answer
    fi
    # 设置CMS_HOST
    set_property CMS_HOST $tenant_host $env_path
    # 开始执行企业初始化操作
    if [[ "$tenant_type" = "isp" ]]; then
        # 赋值企业初始化脚本中的变量
        docker exec -it cms-mysql sh -c 'sed -i "s|{tenant_host}|'$tenant_host'|g" /init_tenant/isp.sql'
        # 执行企业初始化脚本
        docker exec -it cms-mysql sh -c 'mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" ccssx_boot -e "source /init_tenant/isp.sql"' &>/dev/null
        # 修改企业初始化标识
        docker exec -it cms-mysql sh -c 'mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" ccssx_boot -e "update cms_global_config set initialized_flag = 1"' &>/dev/null
    elif [[ "$tenant_type" = "multi" ]]; then
        # 赋值企业初始化脚本中的变量
        docker exec -it cms-mysql sh -c 'sed -i "s|{tenant_host}|'$tenant_host'|g" /init_tenant/multi.sql'
        # 执行企业初始化脚本
        docker exec -it cms-mysql sh -c 'mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" ccssx_boot -e "source /init_tenant/multi.sql"' &>/dev/null
        # 修改企业初始化标识
        docker exec -it cms-mysql sh -c 'mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" ccssx_boot -e "update cms_global_config set initialized_flag = 1"' &>/dev/null
    else
        echo "Unknown error! tenant type is $tenant_type."
        exit 1
    fi
    # 默认账号
    default_account="root"
    # 默认明文密码
    default_dencrypt_password="adminisp"

    echo ""
    echo "Waiting for CMS to start..."
    echo ""
    # 5.启动CMS
    $docker_compose_command down
    $docker_compose_command up -d
    echo ""
    printf "The default tenant account is ${YELLOW}$default_account${RESET} and the password is ${YELLOW}$default_dencrypt_password${RESET}. Please change the root password after logging in to CMS Web."
    echo ""
elif [[ "$action" = "upgrade" ]]; then
    echo "Shutting down CMS..."
    # 开始更新前关闭所有服务
    $docker_compose_command down
    echo "Start upgrading CMS..."

    # 更新.env文件，替换docker-compose文件
    new_env_path=./cms_temp/$env_path
    old_env_path=$env_path
    # 只修改不追加的key
    key_array=(
        "MYSQL_VERSION"
        "REDIS_VERSION"
        "EMQX_VERSION"
        "ROCKET_MQ_VERSION"
        "CMS_ACS_VERSION"
        "CMS_STUN_VERSION"
        "CMS_FTP_VERSION"
        "CMS_BOOT_VERSION"
        "NGINX_VERSION"
    )

    # 定义文件路径
    file_a=$old_env_path
    file_b=$new_env_path
    temp_file=$(mktemp)
    # 从文件A中提取所有的键
    cut -d '=' -f 1 "$file_a" >"$temp_file"
    # 遍历文件B中的每一行
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # 检查行是否为空
        if [[ -n $key ]]; then
            # 检查键是否在文件A中存在
            if ! grep -q "^$key=" "$file_a"; then
                # 如果不存在，则追加到文件A
                echo "$key=$value" >>"$file_a"
            elif contains_element "$key" "${key_array[@]}"; then
                sed -i "s|^$key=.*|$key=$value|" "$file_a"
            fi
        fi
    done <"$file_b"
    # 清理临时文件
    rm "$temp_file"

    echo "Waiting for MySQL to start..."
    # 启动新版本MySQL镜像，并执行数据库升级操作
    $docker_compose_command up -d mysql
    # 循环等待MySQL服务启动成功
    while ! docker exec -it cms-mysql sh -c 'mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" ccssx_boot -BN -e "select 1"' &>/dev/null; do
        echo "Waiting for MySQL to start..."
        sleep 3
    done
    echo "MySQL start successful!!!"

    echo "Start upgrading MySQL..."
    # 开始升级数据库
    docker exec -it cms-mysql sh -c './upgrade.sh'
    docker exec -it cms-mysql sh -c 'cat ./upgrade.log'
    echo "MySQL upgrade successful!!!"
    # 关闭MySQL服务
    $docker_compose_command down

    echo "Waiting for CMS to start..."
    $docker_compose_command up -d
else
    echo "Illegal parameter: $action"
fi
