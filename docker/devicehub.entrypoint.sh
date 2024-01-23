#!/bin/sh

set -e
set -u
# DEBUG
set -x

# 3. Generate an environment .env file.
gen_env_vars() {
        # specific dpp env vars
        if [ "${DPP_MODULE}" = 'y' ]; then
                dpp_env_vars="$(cat <<END
API_DLT='${API_DLT}'
API_DLT_TOKEN='${API_DLT_TOKEN}'
API_RESOLVER='${API_RESOLVER}'
ID_FEDERATED='${ID_FEDERATED}'
END
)"
        fi

        # generate config using env vars from docker
        cat > .env <<END
${dpp_env_vars:-}
DB_USER='${DB_USER}'
DB_PASSWORD='${DB_PASSWORD}'
DB_HOST='${DB_HOST}'
DB_DATABASE='${DB_DATABASE}'
URL_MANUALS='${URL_MANUALS}'

HOST='${HOST}'

SCHEMA='dbtest'
DB_SCHEMA='dbtest'

EMAIL_DEMO='${EMAIL_DEMO}'
PASSWORD_DEMO='${PASSWORD_DEMO}'

JWT_PASS=${JWT_PASS}
SECRET_KEY=${SECRET_KEY}
END
}

wait_for_postgres() {
        # old one was
        #sleep 4

        default_postgres_port=5432
        # thanks https://testdriven.io/blog/dockerizing-django-with-postgres-gunicorn-and-nginx/
        while ! nc -z ${DB_HOST} ${default_postgres_port}; do
                sleep 0.5
        done
}

init_data() {

        # 7. Run alembic of the project.
        alembic -x inventory=dbtest upgrade head
        # 8. Running alembic from oidc module.y
        cd ereuse_devicehub/modules/oidc
        alembic -x inventory=dbtest upgrade head
        cd -
        # 9. Running alembic from dpp module.
        cd ereuse_devicehub/modules/dpp/
        alembic -x inventory=dbtest upgrade head
        cd -

        # 11. Generate a minimal data structure.
        #   TODO it has some errors (?)
        flask initdata || true
}

big_error() {
        local message="${@}"
        echo "###############################################" >&2
        echo "# ERROR: ${message}" >&2
        echo "###############################################" >&2
        exit 1
}

handle_federated_id() {

        # devicehub host and id federated checker

        # //getAll queries are not accepted by this service, so we remove them
        EXPECTED_ID_FEDERATED="$(curl -s "${API_RESOLVER%/}/getAll" \
                | jq -r '.url | to_entries | .[] | select(.value == "'"${DEVICEHUB_HOST}"'") | .key' \
                | head -n 1)"

        # if is a new DEVICEHUB_HOST, then register it
        if [ -z "${EXPECTED_ID_FEDERATED}" ]; then
                # TODO better docker compose run command
                cmd="docker compose run --entrypoint= devicehub flask dlt_insert_members ${DEVICEHUB_HOST}"
                big_error "No FEDERATED ID maybe you should run \`${cmd}\`"
        fi

        # if not new DEVICEHUB_HOST, then check consistency

        # if there is already an ID in the DLT, it should match with my internal ID
        if [ ! "${EXPECTED_ID_FEDERATED}" = "${ID_FEDERATED}" ]; then

                big_error "ID_FEDERATED should be ${EXPECTED_ID_FEDERATED} instead of ${ID_FEDERATED}"
        fi

        # not needed, but reserved
        # EXPECTED_DEVICEHUB_HOST="$(curl -s "${API_RESOLVER%/}/getAll" \
        #         | jq -r '.url | to_entries | .[] | select(.key == "'"${ID_FEDERATED}"'") | .value' \
        #         | head -n 1)"
        # if [ ! "${EXPECTED_DEVICEHUB_HOST}" = "${DEVICEHUB_HOST}" ]; then
        #         big_error "ERROR: DEVICEHUB_HOST should be ${EXPECTED_DEVICEHUB_HOST} instead of ${DEVICEHUB_HOST}"
        # fi

}

config_oidc() {
        # TODO test allowing more than 1 client
        if [ "${ID_SERVICE}" = "server_id" ]; then

                client_description="client identity from docker compose demo"

                # in AUTHORIZED_CLIENT_URL we remove anything before ://
                flask add_contract_oidc \
                      "${EMAIL_DEMO}" \
                      "${client_description}" \
                      "${AUTHORIZED_CLIENT_URL}" \
                      > /shared/client_id_${AUTHORIZED_CLIENT_URL#*://}

        elif [ "${ID_SERVICE}" = "client_id" ]; then

                # in DEVICEHUB_HOST we remove anything before ://
                client_id_config="/shared/client_id_${DEVICEHUB_HOST#*://}"
                client_id=
                client_secret=

                # wait that the file generated by the server_id is readable
                while true; do
                        if [ -f "${client_id_config}" ]; then
                                client_id="$(cat "${client_id_config}" | jq -r '.client_id')"
                                client_secret="$(cat "${client_id_config}" | jq -r '.client_secret')"
                                if [ "${client_id}" ] && [ "${client_secret}" ]; then
                                        break
                                fi
                        fi
                        sleep 1
                done

                flask add_client_oidc \
                      "${SERVER_ID_HOST}" \
                      "${client_id}" \
                      "${client_secret}"

        else
                big_error "Something went wrong ${ID_SERVICE} is not server_id nor client_id"
        fi
}

config_dpp_part1() {
        # 12. Add a new server to the 'api resolver'
        handle_federated_id

        # 13. Do a rsync api resolve
        flask dlt_rsync_members

        # 14. Register a new user to the DLT
        #flask dlt_register_user "${EMAIL_DEMO}" ${PASSWORD_DEMO} Operator
}

config_dpp_part2() {
        # 16.
        flask check_install "${EMAIL_DEMO}" ${PASSWORD_DEMO}
        # 20. config server or client ID
        config_oidc
}

config_phase() {
        init_flagfile='docker__already_configured'
        if [ ! -f "${init_flagfile}" ]; then
                # 7, 8, 9, 11
                init_data

                if [ "${DPP_MODULE}" = 'y' ]; then
                        # 12, 13, 14
                        config_dpp_part1
                fi

                # non DL user (only for the inventory)
                #   flask adduser user2@dhub.com ${PASSWORD_DEMO}

                # # 15. Add inventory snapshots for user "${EMAIL_DEMO}".
                if [ "${IMPORT_SNAPSHOTS}" = 'y' ]; then
                        cp /mnt/snapshots/snapshot*.json ereuse_devicehub/commands/snapshot_files
                        /usr/bin/time flask snapshot "${EMAIL_DEMO}" ${PASSWORD_DEMO}
                fi

                if [ "${DPP_MODULE}" = 'y' ]; then
                        # 16, 20
                        config_dpp_part2
                fi

                # remain next command as the last operation for this if conditional
                touch "${init_flagfile}"
        fi
}

main() {

        gen_env_vars

        wait_for_postgres

        config_phase

        # 17. Use gunicorn
        #   thanks https://akira3030.github.io/formacion/articulos/python-flask-gunicorn-docker.html
        if [ "${DEPLOYMENT:-}" = "PROD" ]; then
                gunicorn --access-logfile - --error-logfile - --workers 4 -b :5000 app:app
        else
                # run development server
                FLASK_DEBUG=1 flask run --host=0.0.0.0 --port 5000
        fi

        # DEBUG
        #sleep infinity
}

main "${@}"
